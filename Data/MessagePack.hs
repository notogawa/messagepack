{-|
Module      : Data.MessagePack
Description : Object data type with Serialize instances for it
Copyright   : (c) Rodrigo Setti, 2014
License     : MIT
Maintainer  : rodrigosetti@gmail.com
Stability   : experimental
Portability : portable

@Object@ is a message pack object, and it have constructors for all message
pack types.

The @Serialize@ instances define how Object values may be serialized and
deserialized to message pack binary format, following the specification.
-}
module Data.MessagePack where

import Control.Applicative
import Control.Monad
import Data.Bits
import Data.Int
import Data.MessagePack.Spec
import Data.Serialize
import Data.Text (Text)
import Data.Text.Encoding
import qualified Data.ByteString  as BS
import qualified Data.Map as M

data Object = ObjectInt Int
            | ObjectNil
            | ObjectBool   Bool
            | ObjectFloat  Float
            | ObjectDouble Double
            | ObjectString Text
            | ObjectBinary BS.ByteString
            | ObjectArray  [Object]
            | ObjectMap    (M.Map Object Object )
    deriving (Eq, Ord, Show)

instance Serialize Object where

    put (ObjectInt i)
          | i >= 0   && i <= 127        = putWord8 $ fromIntegral i
          | i >= -32 && i <= -1         = putWord8 $ fromIntegral i
          | i >= 0   && i < 0x100       = putWord8 uint8  >> putWord8    (fromIntegral i)
          | i >= 0   && i < 0x10000     = putWord8 uint16 >> putWord16be (fromIntegral i)
          | i >= 0   && i < 0x100000000 = putWord8 uint32 >> putWord32be (fromIntegral i)
          | i >= 0                      = putWord8 uint64 >> putWord64be (fromIntegral i)
          | i >= -0x80                  = putWord8 int8   >> putWord8    (fromIntegral i)
          | i >= -0x8000                = putWord8 int16  >> putWord16be (fromIntegral i)
          | i >= -0x80000000            = putWord8 int32  >> putWord32be (fromIntegral i)
          | otherwise                   = putWord8 int64  >> putWord64be (fromIntegral i)

    put ObjectNil          = putWord8 nil

    put (ObjectBool b)     = putWord8 $ if b then true else false

    put (ObjectFloat f)    = putWord8 float32 >> putFloat32be f

    put (ObjectDouble d)   = putWord8 float64 >> putFloat64be d

    put (ObjectString t) =
        header >> mapM_ put (BS.unpack bytes)
     where
        bytes = encodeUtf8 t
        size  = BS.length bytes
        header
          | size <= 31     = putWord8 $ fixstr .|. fromIntegral size
          | size < 0x100   = putWord8 str8  >> putWord8 (fromIntegral size)
          | size < 0x10000 = putWord8 str16 >> putWord16be (fromIntegral size)
          | otherwise      = putWord8 str32 >> putWord32be (fromIntegral size)

    put (ObjectBinary b) =
        header >> mapM_ put (BS.unpack b)
      where
        size  = BS.length b
        header
          | size < 0x100   = putWord8 bin8  >> putWord8 (fromIntegral size)
          | size < 0x10000 = putWord8 bin16 >> putWord16be (fromIntegral size)
          | otherwise      = putWord8 bin32 >> putWord32be (fromIntegral size)

    put (ObjectArray a)    =
        buildArray >> mapM_ put a
      where
        size = length a
        buildArray
          | size <= 15     = putWord8 $ fixarray .|. fromIntegral size
          | size < 0x10000 = putWord8 array16 >> putWord16be (fromIntegral size)
          | otherwise      = putWord8 array32 >> putWord32be (fromIntegral size)

    put (ObjectMap m)      =
        buildMap >> mapM_ put (M.toList m)
      where
        size = M.size m
        buildMap
            | size <= 15     = putWord8 $ fixmap .|. fromIntegral size
            | size < 0x10000 = putWord8 map16 >> putWord16be (fromIntegral size)
            | otherwise      = putWord8 map32 >> putWord32be (fromIntegral size)

    get =
        getWord8 >>= getObject
      where
        getObject k
          | k == nil                          = return ObjectNil
          | k == false                        = return $ ObjectBool False
          | k == true                         = return $ ObjectBool True

          | k == bin8                         = do n <- fromIntegral <$> getWord8
                                                   ObjectBinary <$> getBytes n
          | k == bin16                        = do n <- fromIntegral <$> getWord16be
                                                   ObjectBinary <$> getBytes n
          | k == bin32                        = do n <- fromIntegral <$> getWord32be
                                                   ObjectBinary <$> getBytes n

          | k == float32                      = ObjectFloat  <$> getFloat32be
          | k == float64                      = ObjectDouble <$> getFloat64be

          | k .&. posFixintMask == posFixint  = return $ ObjectInt $ fromIntegral k
          | k .&. negFixintMask == negFixint  = return $ ObjectInt $ fromIntegral (fromIntegral k :: Int8)
          | k == uint8                        = ObjectInt <$> fromIntegral <$> getWord8
          | k == uint16                       = ObjectInt <$> fromIntegral <$> getWord16be
          | k == uint32                       = ObjectInt <$> fromIntegral <$> getWord32be
          | k == uint64                       = ObjectInt <$> fromIntegral <$> getWord64be
          | k == int8                         = ObjectInt <$> fromIntegral <$> (get :: Get Int8)
          | k == int16                        = ObjectInt <$> fromIntegral <$> (get :: Get Int16)
          | k == int32                        = ObjectInt <$> fromIntegral <$> (get :: Get Int32)
          | k == int64                        = ObjectInt <$> fromIntegral <$> (get :: Get Int64)

          | k .&. fixstrMask    == fixstr     = let n = fromIntegral $ k .&. complement fixstrMask
                                                in  ObjectString <$> decodeUtf8 <$> getBytes n
          | k == str8                         = do n <- fromIntegral <$> getWord8
                                                   ObjectString <$> decodeUtf8 <$> getBytes n
          | k == str16                        = do n <- fromIntegral <$> getWord16be
                                                   ObjectString <$> decodeUtf8 <$> getBytes n
          | k == str32                        = do n <- fromIntegral <$> getWord32be
                                                   ObjectString <$> decodeUtf8 <$> getBytes n

          | k .&. fixarrayMask  == fixarray   = let n = fromIntegral $ k .&. complement fixarrayMask
                                                in  ObjectArray <$> replicateM n get
          | k == array16                      = do n <- fromIntegral <$> getWord16be
                                                   ObjectArray <$> replicateM n get
          | k == array32                      = do n <- fromIntegral <$> getWord32be
                                                   ObjectArray <$> replicateM n get

          | k .&. fixmapMask    == fixmap     = let n = fromIntegral $ k .&. complement fixmapMask
                                                in  ObjectMap <$> M.fromList <$> replicateM n get
          | k == map16                        = do n <- fromIntegral <$> getWord16be
                                                   ObjectMap <$> M.fromList <$> replicateM n get
          | k == map32                        = do n <- fromIntegral <$> getWord32be
                                                   ObjectMap <$> M.fromList <$> replicateM n get

          | otherwise                         = fail $ "mark byte not supported: " ++ show k

