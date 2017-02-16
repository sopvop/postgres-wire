{-# language RecordWildCards #-}

module Database.PostgreSQL.Protocol.Decoders
    ( 
    -- * High-lever decoder
      decodeNextServerMessage
    -- * Decoders
    , decodeAuthResponse
    , decodeHeader
    , decodeServerMessage
    -- * Helpers
    , parseServerVersion
    , parseIntegerDatetimes
    , parseErrorDesc
    ) where

import           Data.Monoid ((<>))
import           Data.Maybe (fromMaybe)
import           Data.Char (chr)
import           Data.Word (Word8, Word16, Word32)
import           Text.Read (readMaybe)
import qualified Data.Vector as V
import qualified Data.ByteString as B
import           Data.ByteString.Char8 as BS(readInteger, readInt, unpack, pack)
import qualified Data.HashMap.Strict as HM

import Database.PostgreSQL.Protocol.Types
import Database.PostgreSQL.Protocol.Store.Decode

-- | Parses and dispatches all server messages except `DataRow`.
decodeNextServerMessage
    -- Initial buffer to parse from
    :: B.ByteString
    -- Action that returs more data with `ByteString` prepended.
    -> (B.ByteString -> IO B.ByteString)
    -> IO (B.ByteString, ServerMessage)
decodeNextServerMessage bs readMoreAction = go Nothing bs
  where
    -- Parse header
    go Nothing bs
        | B.length bs < headerSize = readMoreAndGo Nothing bs
        | otherwise = let (rest, h) = runDecode decodeHeader bs
                      in go (Just h) rest
    -- Parse body
    go (Just h@(Header _ len)) bs
        | B.length bs < len = readMoreAndGo (Just h) bs
        | otherwise = pure $ runDecode (decodeServerMessage h) bs

    {-# INLINE readMoreAndGo #-}
    readMoreAndGo h = (go h =<<) . readMoreAction

--------------------------------
-- Protocol decoders

decodeAuthResponse :: Decode AuthResponse
decodeAuthResponse = do
    Header c len <- decodeHeader
    case chr $ fromIntegral c of
        'E' -> AuthErrorResponse <$>
            (getByteString len >>=
                eitherToDecode .parseErrorDesc)
        'R' -> do
            rType <- getInt32BE
            case rType of
                0 -> pure AuthenticationOk
                3 -> pure AuthenticationCleartextPassword
                5 -> AuthenticationMD5Password . MD5Salt <$> getByteString 4
                7 -> pure AuthenticationGSS
                9 -> pure AuthenticationSSPI
                8 -> AuthenticationGSSContinue <$> getByteString (len - 4)
                _ -> fail "Unknown authentication response"
        _ -> fail "Invalid auth response"

decodeHeader :: Decode Header
decodeHeader = Header <$> getWord8 <*>
                (fromIntegral . subtract 4 <$> getInt32BE)

decodeServerMessage :: Header -> Decode ServerMessage
decodeServerMessage (Header c len) = case chr $ fromIntegral c of
    'K' -> BackendKeyData <$> (ServerProcessId <$> getInt32BE)
                          <*> (ServerSecretKey <$> getInt32BE)
    '2' -> pure BindComplete
    '3' -> pure CloseComplete
    'C' -> CommandComplete <$> (getByteString len
                                >>= eitherToDecode . parseCommandResult)
    -- Dont parse data rows here.
    'D' -> do
        _ <- getByteString len
        pure DataRow
    'I' -> pure EmptyQueryResponse
    'E' -> ErrorResponse <$>
        (getByteString len >>=
            eitherToDecode . parseErrorDesc)
    'n' -> pure NoData
    'N' -> NoticeResponse <$>
        (getByteString len >>=
            eitherToDecode . parseNoticeDesc)
    'A' -> NotificationResponse <$> decodeNotification
    't' -> do
        paramCount <- fromIntegral <$> getInt16BE
        ParameterDescription <$> V.replicateM paramCount
                                 (Oid <$> getInt32BE)
    'S' -> ParameterStatus <$> getByteStringNull <*> getByteStringNull
    '1' -> pure ParseComplete
    's' -> pure PortalSuspended
    'Z' -> ReadyForQuery <$> decodeTransactionStatus
    'T' -> do
        rowsCount <- fromIntegral <$> getInt16BE
        RowDescription <$> V.replicateM rowsCount decodeFieldDescription

decodeTransactionStatus :: Decode TransactionStatus
decodeTransactionStatus =  getWord8 >>= \t ->
    case chr $ fromIntegral t of
        'I' -> pure TransactionIdle
        'T' -> pure TransactionInBlock
        'E' -> pure TransactionFailed
        _   -> fail "unknown transaction status"

decodeFieldDescription :: Decode FieldDescription
decodeFieldDescription = FieldDescription
    <$> getByteStringNull
    <*> (Oid <$> getInt32BE)
    <*> getInt16BE
    <*> (Oid <$> getInt32BE)
    <*> getInt16BE
    <*> getInt32BE
    <*> decodeFormat

decodeNotification :: Decode Notification
decodeNotification = Notification
    <$> (ServerProcessId <$> getInt32BE)
    <*> (ChannelName <$> getByteStringNull)
    <*> getByteStringNull

decodeFormat :: Decode Format
decodeFormat = getInt16BE >>= \f ->
    case f of
        0 -> pure Text
        1 -> pure Binary
        _ -> fail "Unknown field format"

-----------------------------
-- Helper parsers that work with B.ByteString, not Decode type

-- Helper to parse, not used by decoder itself
parseServerVersion :: B.ByteString -> Either B.ByteString ServerVersion
parseServerVersion bs =
    let (numbersStr, desc) = B.span isDigitDot bs
        numbers = readMaybe . BS.unpack <$> B.split 46 numbersStr
    in case numbers ++ repeat (Just 0) of
        (Just major : Just minor : Just rev : _) ->
            Right $ ServerVersion major minor rev desc
        _ -> Left $ "Unknown server version" <> bs
  where
    isDigitDot c | c == 46           = True -- dot
                 | c >= 48 && c < 58 = True -- digits
                 | otherwise         = False

-- Helper to parse, not used by decoder itself
parseIntegerDatetimes :: B.ByteString -> Either B.ByteString Bool
parseIntegerDatetimes  bs
    | bs == "on" || bs == "yes" || bs == "1" = Right True
    | otherwise                              = Right False

parseCommandResult :: B.ByteString -> Either B.ByteString CommandResult
parseCommandResult s =
    let (command, rest) = B.break (== space) s
    in case command of
        -- format: `INSERT oid rows`
        "INSERT" ->
            maybe (Left "Invalid format in INSERT command result") Right $ do
                (oid, r) <- readInteger $ B.dropWhile (== space) rest
                (rows, _) <- readInteger $ B.dropWhile (== space) r
                Just $ InsertCompleted (Oid $ fromInteger oid)
                                       (RowsCount $ fromInteger rows)
        "DELETE" -> DeleteCompleted <$> readRows rest
        "UPDATE" -> UpdateCompleted <$> readRows rest
        "SELECT" -> SelectCompleted <$> readRows rest
        "MOVE"   -> MoveCompleted   <$> readRows rest
        "FETCH"  -> FetchCompleted  <$> readRows rest
        "COPY"   -> CopyCompleted   <$> readRows rest
        _        -> Right CommandOk
  where
    space = 32
    readRows = maybe (Left "Invalid rows format in command result")
                       (pure . RowsCount . fromInteger . fst)
                       . readInteger . B.dropWhile (== space)

parseErrorNoticeFields
    :: B.ByteString -> Either B.ByteString (HM.HashMap Char B.ByteString)
parseErrorNoticeFields = Right . HM.fromList
    . fmap (\s -> (chr . fromIntegral $ B.head s, B.tail s))
    . filter (not . B.null) . B.split 0

parseErrorSeverity :: B.ByteString -> Either B.ByteString ErrorSeverity
parseErrorSeverity bs = Right $ case bs of
    "ERROR" -> SeverityError
    "FATAL" -> SeverityFatal
    "PANIC" -> SeverityPanic
    _       -> UnknownErrorSeverity

parseNoticeSeverity :: B.ByteString -> Either B.ByteString NoticeSeverity
parseNoticeSeverity bs = Right $ case bs of
    "WARNING" -> SeverityWarning
    "NOTICE"  -> SeverityNotice
    "DEBUG"   -> SeverityDebug
    "INFO"    -> SeverityInfo
    "LOG"     -> SeverityLog
    _         -> UnknownNoticeSeverity

parseErrorDesc :: B.ByteString -> Either B.ByteString ErrorDesc
parseErrorDesc s = do
    hm               <- parseErrorNoticeFields s
    errorSeverityOld <- lookupKey 'S' hm
    errorCode        <- lookupKey 'C' hm
    errorMessage     <- lookupKey 'M' hm
    -- This is identical to the S field except that the contents are
    -- never localized. This is present only in messages generated by
    -- PostgreSQL versions 9.6 and later.
    let errorSeverityNew  = HM.lookup 'V' hm
    errorSeverity         <- parseErrorSeverity $
                            fromMaybe errorSeverityOld errorSeverityNew
    let
        errorDetail           = HM.lookup 'D' hm
        errorHint             = HM.lookup 'H' hm
        errorPosition         = HM.lookup 'P' hm >>= fmap fst . readInt
        errorInternalPosition = HM.lookup 'p' hm >>= fmap fst . readInt
        errorInternalQuery    = HM.lookup 'q' hm
        errorContext          = HM.lookup 'W' hm
        errorSchema           = HM.lookup 's' hm
        errorTable            = HM.lookup 't' hm
        errorColumn           = HM.lookup 'c' hm
        errorDataType         = HM.lookup 'd' hm
        errorConstraint       = HM.lookup 'n' hm
        errorSourceFilename   = HM.lookup 'F' hm
        errorSourceLine       = HM.lookup 'L' hm >>= fmap fst . readInt
        errorSourceRoutine    = HM.lookup 'R' hm
    Right ErrorDesc{..}
  where
    lookupKey c = maybe (Left $ "Neccessary key " <> BS.pack (show c) <>
                         "is not presented in ErrorResponse message")
                         Right . HM.lookup c

parseNoticeDesc :: B.ByteString -> Either B.ByteString NoticeDesc
parseNoticeDesc s = do
    hm                <- parseErrorNoticeFields s
    noticeSeverityOld <- lookupKey 'S' hm
    noticeCode        <- lookupKey 'C' hm
    noticeMessage     <- lookupKey 'M' hm
    -- This is identical to the S field except that the contents are
    -- never localized. This is present only in messages generated by
    -- PostgreSQL versions 9.6 and later.
    let noticeSeverityNew = HM.lookup 'V' hm
    noticeSeverity        <- parseNoticeSeverity $
                            fromMaybe noticeSeverityOld noticeSeverityNew
    let
        noticeDetail           = HM.lookup 'D' hm
        noticeHint             = HM.lookup 'H' hm
        noticePosition         = HM.lookup 'P' hm >>= fmap fst . readInt
        noticeInternalPosition = HM.lookup 'p' hm >>= fmap fst . readInt
        noticeInternalQuery    = HM.lookup 'q' hm
        noticeContext          = HM.lookup 'W' hm
        noticeSchema           = HM.lookup 's' hm
        noticeTable            = HM.lookup 't' hm
        noticeColumn           = HM.lookup 'c' hm
        noticeDataType         = HM.lookup 'd' hm
        noticeConstraint       = HM.lookup 'n' hm
        noticeSourceFilename   = HM.lookup 'F' hm
        noticeSourceLine       = HM.lookup 'L' hm >>= fmap fst . readInt
        noticeSourceRoutine    = HM.lookup 'R' hm
    Right NoticeDesc{..}
  where
    lookupKey c = maybe (Left $ "Neccessary key " <> BS.pack (show c) <>
                         "is not presented in NoticeResponse message")
                         Right . HM.lookup c

-- | Helper to lift Either in Decode
eitherToDecode :: Either B.ByteString a -> Decode a
eitherToDecode = either (fail . BS.unpack) pure

