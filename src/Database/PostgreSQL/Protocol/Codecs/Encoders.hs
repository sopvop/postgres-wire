module Database.PostgreSQL.Protocol.Codecs.Encoders where

import Data.Word
import Data.Monoid ((<>))
import Data.Int
import Data.Char
import Data.Fixed
import Data.UUID (UUID, toByteString)
import Data.Time (Day, UTCTime, LocalTime, DiffTime)
import qualified Data.ByteString as B
import qualified Data.Vector as V

import Control.Monad

import Database.PostgreSQL.Protocol.Store.Encode
import Database.PostgreSQL.Protocol.Types
import Database.PostgreSQL.Protocol.Codecs.Time
import Database.PostgreSQL.Protocol.Codecs.Numeric
--
-- Primitives
--

{-# INLINE bool #-}
bool :: Bool -> Encode
bool False = putWord8 0
bool True  = putWord8 1

{-# INLINE bytea #-}
bytea :: B.ByteString -> Encode
bytea = putByteString

{-# INLINE char #-}
char :: Char -> Encode
char = putWord8 . fromIntegral . ord 

{-# INLINE date #-}
date :: Day -> Encode
date = putWord32BE . dayToPgj

{-# INLINE float4 #-}
float4 :: Float -> Encode
float4 = putFloat32BE

{-# INLINE float8 #-}
float8 :: Double -> Encode
float8 = putFloat64BE

{-# INLINE int2 #-}
int2 :: Int16 -> Encode
int2 = putInt16BE

{-# INLINE int4 #-}
int4 :: Int32 -> Encode
int4 = putInt32BE 

{-# INLINE int8 #-}
int8 :: Int64 -> Encode
int8 = putInt64BE 

{-# INLINE interval #-}
interval :: DiffTime -> Encode
interval v = let (mcs, days, months)  = diffTimeToInterval v 
             in putInt64BE mcs <> putInt32BE days <> putInt32BE months

-- | Encodes representation of JSON as @ByteString@.
{-# INLINE bsJsonText #-}
bsJsonText :: B.ByteString -> Encode
bsJsonText = putByteString

-- | Encodes representation of JSONB as @ByteString@.
{-# INLINE bsJsonBytes #-}
bsJsonBytes :: B.ByteString -> Encode
bsJsonBytes bs = putWord8 1 <> putByteString bs

numeric :: HasResolution a => (Fixed a) -> Encode
numeric _ = do undefined
   -- ndigits <- putWord16BE
   -- weight <- putInt16BE
   -- msign <- numericSign <$> putWord16BE
   -- sign <- maybe (fail "unknown numeric") pure msign
   -- dscale <- putWord16BE
   -- digits <- replicateM (fromIntegral ndigits) putWord16BE
   -- pure $ undefined

-- | Encodes text.
{-# INLINE bsText #-}
bsText :: B.ByteString -> Encode
bsText = putByteString

{-# INLINE timestamp #-}
timestamp :: LocalTime -> Encode
timestamp = putWord64BE . localTimeToMicros 

{-# INLINE timestamptz #-}
timestamptz :: UTCTime -> Encode
timestamptz = putWord64BE . utcToMicros 

{-# INLINE uuid #-}
uuid :: UUID -> Encode
uuid = undefined
