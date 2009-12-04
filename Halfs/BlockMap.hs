{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances, BangPatterns #-}
module Halfs.BlockMap
  (
  -- * Types
    BlockGroup(..)
  , BlockMap(..)
  , Extent(..)
  -- * Block Map creation, de/serialization, and query functions
  , newBlockMap
  , readBlockMap
  , writeBlockMap
  , numFreeBlocks
  -- * Block Map allocation/unallocation functions
  , allocBlocks
  , unallocBlocks
  -- * Utility functions
  , blkGroupExts
  , blkGroupSz
  , blkRange
  , blkRangeExt
  , blkRangeBG
  )
 where

import Control.Exception (assert)
import Control.Monad
import Data.Bits hiding (setBit, clearBit)
import qualified Data.Bits as B 
import qualified Data.ByteString as BS
import Data.FingerTree
import qualified Data.Foldable as DF
import Data.Monoid
import Data.Word
import Prelude hiding (null)

import Halfs.Classes
import System.Device.BlockDevice

-- temp
import Debug.Trace
-- temp  

-- ----------------------------------------------------------------------------
--
-- Important block format diagram for a ficticious block device w/ 36 blocks;
-- note that the superblock always consumes exactly one block, while the
-- blockmap itself may span multiple blocks as needed, depending on device
-- geometry.
--
--                      1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3 3 3 3 3
--  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
-- +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
-- |S|M| | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | | |
-- +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
--
--

{-

TODO: 

-}

data BlockGroup = Contig Extent | Discontig [Extent]
  deriving (Show, Eq)

data Extent = Extent { extBase :: Word64, extSz :: Word64 }
  deriving (Show, Eq)

newtype ExtentSize = ES Word64
type    FreeTree   = FingerTree ExtentSize Extent

instance Monoid ExtentSize where
  mempty                = ES minBound
  mappend (ES a) (ES b) = ES (max a b)

instance Measured ExtentSize Extent where
  measure (Extent _ s)  = ES s

splitBlockSz :: Word64 -> FreeTree -> (FreeTree, FreeTree)
splitBlockSz sz = split $ \(ES y) -> y >= sz

insert :: Extent -> FreeTree -> FreeTree
insert ext tr = treeL >< (ext <| treeR)
 where (treeL, treeR) = splitBlockSz (extSz ext) tr

-- ----------------------------------------------------------------------------

data BlockMap b r = BM {
    bmFreeTree :: r FreeTree
  , bmUsedMap  :: b -- ^ Is the given block free?
  , bmNumFree  :: r Word64
  }

-- | Calculate the number of bytes required to store a block map for the
-- given number of blocks
blockMapSizeBytes :: Word64 -> Word64
blockMapSizeBytes numBlks = numBlks `divCeil` 8

-- | Calculate the number of blocks required to store a block map for
-- the given number of blocks.
blockMapSizeBlks :: Word64 -> Word64 -> Word64
blockMapSizeBlks numBlks blkSzBytes = bytes `divCeil` blkSzBytes
  where bytes = blockMapSizeBytes numBlks

-- | Create a new block map for the given device geometry
newBlockMap :: (Monad m, Reffable r m, Bitmapped b m) =>
               BlockDevice m
            -> m (BlockMap b r)
newBlockMap dev = do
  when (numFree == 0) $ fail "Block device is too small for block map creation"

--   trace ("newBlockMap: numBlks = " ++ show numBlks) $ do
--   trace ("newBlockMap: totalBits = " ++ show totalBits) $ do
--   trace ("newBlockMap: blockMapSzBlks = " ++ show blockMapSzBlks) $ do
--   trace ("newBlockMap: baseFreeIdx = " ++ show baseFreeIdx) $ do
--   trace ("newBlockMap: numFree = " ++ show numFree) $ do

  -- We overallocate the bitmap up to the entire size of the block(s)
  -- needed for the block map region so that de/serialization in the
  -- {read,write}BlockMap functions is straightforward
  bArr <- newBitmap totalBits False
  let markUsed (l,h) = forM_ [l..h] (setBit bArr)
  mapM_ markUsed
    [ (0, 0)                   -- superblock
    , (1, blockMapSzBlks)      -- blocks for storing the block map
    , (numBlks, totalBits - 1) -- overallocated region
    ] 
  treeR    <- newRef $ singleton $ Extent baseFreeIdx numFree
  numFreeR <- newRef numFree
  return $ assert (baseFreeIdx + numFree == numBlks) $
    BM treeR bArr numFreeR
 where
  numBlks        = bdNumBlocks dev
  totalBits      = blockMapSzBlks * bdBlockSize dev * 8
  blockMapSzBlks = blockMapSizeBlks numBlks (bdBlockSize dev)
  baseFreeIdx    = blockMapSzBlks + 1
  numFree        = numBlks - blockMapSzBlks - 1 {- -1 for superblock -}

-- | Read in the block map from the disk
readBlockMap :: (Monad m, Reffable r m, Bitmapped b m) =>
                BlockDevice m
             -> m (BlockMap b r)
readBlockMap dev = do
  bArr  <- newBitmap totalBits False
  freeR <- newRef 0

  -- Unpack the block map's block region into the empty bitmap
  forM_ [0..blockMapSzBlks - 1] $ \blkIdx -> do
    blockBS <- bdReadBlock dev (blkIdx + 1 {- +1 for superblock -})
    forM_ [0..bdBlockSize dev - 1] $ \byteIdx -> do
      let byte = BS.index blockBS (fromIntegral byteIdx)
      forM_ [0..7] $ \bitIdx -> do
        if (testBit byte bitIdx)
         then do let baseByte = blkIdx * bdBlockSize dev
                     idx      = (baseByte + byteIdx) * 8 + fromIntegral bitIdx 
                 setBit bArr idx
         else do cur <- readRef freeR
                 writeRef freeR $! cur + 1
  
  baseTreeR <- newRef empty
  getFreeBlocks bArr baseTreeR Nothing 0
  return $ BM baseTreeR bArr freeR
 where
  numBlks        = bdNumBlocks dev
  totalBits      = blockMapSzBlks * bdBlockSize dev * 8
  blockMapSzBlks = blockMapSizeBlks numBlks (bdBlockSize dev)
  -- 
  writeExtent treeR ext = do
    t <- readRef treeR
    writeRef treeR $! insert ext t
  -- 
  -- getFreeBlocks recurses over each used bit in the used bitmap and
  -- finds runs of free block regions, inserting representative Extents
  -- into the "free tree" as it does so.  The third parameter tracks the
  -- block address of start of the current free region.
  getFreeBlocks _bmap treeR mbase cur | cur == totalBits =
    maybe (return ())
          (\base -> writeExtent treeR (Extent base $ cur - base))
          mbase

  getFreeBlocks bmap treeR Nothing cur = do
    used <- checkBit bmap cur
    getFreeBlocks bmap treeR (if used then Nothing else Just cur) (cur + 1)

  getFreeBlocks bmap treeR b@(Just base) cur = do
    used <- checkBit bmap cur
    when used $ writeExtent treeR (Extent base $ cur - base)
    getFreeBlocks bmap treeR (if used then Nothing else b) (cur + 1)

-- | Write the block map to the disk
writeBlockMap :: (Monad m, Reffable r m, Bitmapped b m, Functor m) =>
                 BlockDevice m
              -> BlockMap b r
              -> m ()
writeBlockMap dev bmap = do
  -- Pack the used bitmap into the block map's block region
  forM_ [0..blockMapSzBlks - 1] $ \blkIdx -> do
    blockBS <- BS.pack `fmap` forM [0..bdBlockSize dev - 1] (getBytes blkIdx)
    bdWriteBlock dev (blkIdx + 1 {- +1 for superblock -}) blockBS
  where
    numBlks        = bdNumBlocks dev
    blockMapSzBlks = blockMapSizeBlks numBlks (bdBlockSize dev)
    --
    getBytes blkIdx byteIdx = do
      bs <- forM [0..7] $ \bitIdx -> do
        let base = blkIdx * bdBlockSize dev
            idx  = (base + byteIdx) * 8 + bitIdx
        checkBit (bmUsedMap bmap) idx
      return $ foldr (\(b,i) r -> if b then B.setBit r i else r)
               (0::Word8) (bs `zip` [0..7])
            
-- | Allocate a set of blocks from the disk. This routine will attempt
-- to fetch a contiguous set of blocks, but isn't guaranteed to do so.
-- Contiguous blocks are represented via the Contig constructor of the
-- BlockGroup datatype, discontiguous blocks via Discontig.  If there
-- aren't enough blocks available, this function yields Nothing.
allocBlocks :: (Monad m, Reffable r m, Bitmapped b m) =>
               BlockMap b r
            -- ^ the block map 
            -> Word64
            -- ^ requested number of blocks to allocate
            -> m (Maybe BlockGroup)
allocBlocks bm numBlocks = do
  available <- readRef $! bmNumFree bm
  if available < numBlocks
    then do
      return Nothing
    else do
      freeTree <- readRef $! bmFreeTree bm
      let (blkGroup, freeTree') = findSpace numBlocks freeTree
      forM_ (blkRangeBG blkGroup) $ setBit $ bmUsedMap bm
      writeRef (bmFreeTree bm) freeTree'
      writeRef (bmNumFree bm) (available - numBlocks)
      return $ Just blkGroup

-- | Mark a given block group as unused
unallocBlocks :: (Monad m, Reffable r m, Bitmapped b m) =>
                 BlockMap b r -- ^ the block map
              -> BlockGroup
              -> m ()
unallocBlocks bm (Discontig exts) = mapM_ (unallocBlocks bm . Contig) exts
unallocBlocks bm (Contig ext)     = do
  avail    <- numFreeBlocks bm
  freeTree <- readRef $! bmFreeTree bm
  forM_ (blkRangeExt ext) $ clearBit $ bmUsedMap bm
  writeRef (bmFreeTree bm) $ insert ext freeTree
  writeRef (bmNumFree bm)  $ avail + extSz ext

-- | Return the number of blocks currently left
numFreeBlocks :: (Monad m, Reffable r m, Bitmapped b m) =>
                 BlockMap b r
              -> m Word64
numFreeBlocks = readRef . bmNumFree

findSpace :: Word64 -> FreeTree -> (BlockGroup, FreeTree)
findSpace goalSz freeTree =
  -- Precondition: There is sufficient space in the free tree to accomodate the
  -- given goal size, although that space may not be contiguous
  assert (goalSz <= DF.foldr ((+) . extSz) 0 freeTree) $ do
  let (treeL, treeR) = splitBlockSz goalSz freeTree
  case viewl treeR of
    Extent b sz :< treeR' -> 
      -- Found an extent with size >= the goal size
      ( Contig $ Extent b goalSz 
      , -- Split the found extent when it exceeds the goal size
        let mid = if sz > goalSz
                  then singleton $ Extent (b + goalSz) (sz - goalSz)
                  else empty
        in treeL >< mid >< treeR'
      )

    EmptyL ->
      -- Cannot find an extent large enough, so gather smaller extents
      fmapFst Discontig $ gatherL (viewr treeL) 0 []
      where
        gatherL :: ViewR (FingerTree ExtentSize) Extent
                -> Word64
                -> [Extent]
                -> ([Extent], FreeTree)
        gatherL EmptyR _ _ = error "Precondition violated: insufficent space"
        gatherL (treeL' :> ext@(Extent b sz)) accSz accExts
          | accSz + sz < goalSz = gatherL (viewr treeL')
                                          (accSz + sz)
                                          (ext : accExts) 
          | accSz + sz == goalSz = (ext : accExts, treeL')
          | otherwise = 
            -- We've exceeded the goal, so split the extent we just encountered
            (Extent (b + diff) (sz - diff) : accExts, treeL' >< extra)
            where diff  = accSz + sz - goalSz
                  extra = singleton $ Extent b diff

--------------------------------------------------------------------------------
-- Utility functions

blkRange :: Word64 -> Word64 -> [Word64]
blkRange b sz = [b .. b + sz - 1]

blkRangeExt :: Extent -> [Word64]
blkRangeExt (Extent b sz) = blkRange b sz

blkRangeBG :: BlockGroup -> [Word64]
blkRangeBG (Contig ext)     = blkRangeExt ext
blkRangeBG (Discontig exts) = concatMap blkRangeExt exts

blkGroupExts :: BlockGroup -> [Extent]
blkGroupExts (Contig ext)     = [ext]
blkGroupExts (Discontig exts) = exts

blkGroupSz :: BlockGroup -> Word64
blkGroupSz (Contig ext)     = extSz ext
blkGroupSz (Discontig exts) = foldr (\e -> (extSz e +)) 0 exts

divCeil :: Integral a => a -> a -> a
divCeil a b = (a + (b - 1)) `div` b

fmapFst :: (a -> b) -> (a, c) -> (b, c)
fmapFst f (x,y) = (f x, y)
