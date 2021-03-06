module Main (main) where

import ClassyPrelude
import Codec.Binary.UTF8.String(decode)
import Data.ByteString.Char8 (ByteString)
import System.FilePath.Find (fileType, fileName, FileType(..), (==?), (&&?))
import qualified System.FilePath.Find as File
import System.Posix.Types (GroupID, UserID, FileOffset, Fd, ByteCount)
import System.Posix.Files
    (
        unionFileModes,
        otherExecuteMode,
        otherReadMode,
        groupExecuteMode,
        groupReadMode,
        ownerExecuteMode,
        ownerReadMode
    )
import System.Posix.IO (OpenMode, OpenFileFlags, closeFd, openFd)
import "unix-bytestring" System.Posix.IO.ByteString (fdPread, fdPwrite)
import Foreign.C.Error (Errno, eOK, eNOENT, eNOTDIR, eNOSYS, eINVAL)
import System.Fuse
    (
        fuseMain,
        fuseGetFileSystemStats,
        fuseReadDirectory,
        fuseOpenDirectory,
        fuseFlush,
        fuseWrite,
        fuseRead,
        fuseOpen,
        fuseReadSymbolicLink,
        fuseGetFileStat,
        defaultFuseOps,
        FuseOperations
    )
import qualified System.Fuse as Fuse
import Data.Map.Lazy (Map)
import qualified Data.Map.Strict as Map
import System.FilePath (takeFileName, takeDirectory, splitPath)
import Data.List (dropWhileEnd)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import Data.Either (fromLeft)
import System.Directory (makeAbsolute)
import System.FSNotify (watchTree, withManager, eventPath, Event(..), Event)
import Control.Concurrent.Extra (newLock, newVar, writeVar, readVar, withLock, Var, Lock)

-- TODO: Convert exceptions to their corresponding `errno`.
data TagHandle = External Fd | Internal
data TagTree = Link FilePath | Dir (Map FilePath TagTree) deriving Show

instance Semigroup TagTree where
    -- Favour links over directories, as links are results.
    x <> y = case (x, y) of
        (Link _, _) -> x
        (_, Link _) -> y
        (Dir entriesX, Dir entriesY) -> Dir $ Map.unionWith mappend entriesX entriesY

instance Monoid TagTree where
    mempty = Dir Map.empty
    mappend = (<>)

pathComponents :: FilePath -> [FilePath]
pathComponents path = filter (/= "") (dropWhileEnd (== '/') <$> splitPath path)

lookupPath :: FilePath -> Var TagTree -> IO (Maybe TagTree)
lookupPath path tagTreeHandle =
    let
        go fp tree = case (tree, fp) of
            (_, []) -> Just tree
            (Dir entries, name : tailPath) -> Map.lookup name entries >>= go tailPath
            _ -> Nothing
    in do
        tagTree <- readVar tagTreeHandle
        pure $ go (pathComponents path) tagTree

getEntryType :: TagTree -> Fuse.EntryType
getEntryType = \case
    Dir _ -> Fuse.Directory
    Link _ -> Fuse.SymbolicLink

ifExists :: Var TagTree -> FilePath -> (TagTree -> IO (Either Errno a)) -> IO (Either Errno a)
ifExists tree fp f = do
    path <- lookupPath fp tree
    maybe (pure $ Left eNOENT) f path

getFileStat :: MkStat -> Var TagTree -> FilePath -> IO (Either Errno Fuse.FileStat)
getFileStat (MkStat stat) tree fp = ifExists tree fp (pure . Right . stat . getEntryType)

readSymLink :: Var TagTree -> FilePath -> IO (Either Errno FilePath)
readSymLink tree fp =
    let
        symLinkDest = pure . \case
            Link dest -> Right dest
            Dir _ -> Left eINVAL
    in ifExists tree fp symLinkDest

passThrough :: TagHandle -> (Fd -> IO a) -> IO (Either Errno a)
passThrough h f = case h of
    External fd -> Right <$> f fd
    Internal -> pure $ Left eNOSYS

openFile  :: Var TagTree -> FilePath -> OpenMode -> OpenFileFlags -> IO (Either Errno TagHandle)
openFile tree fp mode flags =
    let
        openAt = \case
            Link dest -> (Right . External) <$> openFd dest mode Nothing flags
            Dir _ -> pure $ Right Internal
    in ifExists tree fp openAt

readExternalFile :: FilePath -> TagHandle -> ByteCount -> FileOffset -> IO (Either Errno ByteString)
readExternalFile _ h bc offset = passThrough h $ \fd -> fdPread fd bc offset

writeExternalFile ::  FilePath -> TagHandle -> ByteString -> FileOffset -> IO (Either Errno ByteCount)
writeExternalFile _ h buf offset = passThrough h $ \fd -> fdPwrite fd buf offset

flushFile ::  FilePath -> TagHandle -> IO Errno
flushFile _ h = fromLeft eOK <$> passThrough h closeFd

openDirectory :: Var TagTree -> FilePath -> IO Errno
openDirectory tree fp = do
    path <- lookupPath fp tree
    pure $ maybe eNOENT (const eOK) path

readDirectory :: MkStat -> Var TagTree -> FilePath -> IO (Either Errno [(FilePath, Fuse.FileStat)])
readDirectory (MkStat stat) tree path =
    let
        addStat = stat . getEntryType
        readIfDir = pure . \case
            Link _ -> Left eNOTDIR
            Dir entries -> Right $ ((addStat <$>) <$> Map.toList entries)
    in ifExists tree path readIfDir

getFileSystemStats :: String -> IO (Either Errno Fuse.FileSystemStats)
getFileSystemStats = const $ pure $ Right $ Fuse.FileSystemStats
    {
        Fuse.fsStatBlockSize = 512,
        Fuse.fsStatBlockCount = 0,
        Fuse.fsStatBlocksFree = 0,
        Fuse.fsStatBlocksAvailable = 0,
        Fuse.fsStatFileCount = 0,
        Fuse.fsStatFilesFree = 0,
        Fuse.fsStatMaxNameLength = 255
    }

fsOps :: Var TagTree -> MkStat -> FuseOperations TagHandle
fsOps tree stat = defaultFuseOps
    {
        fuseGetFileStat = getFileStat stat tree,
        fuseReadSymbolicLink = readSymLink tree,
        fuseOpen = openFile tree,
        fuseRead = readExternalFile,
        fuseWrite = writeExternalFile,
        fuseFlush = flushFile,
        fuseOpenDirectory = openDirectory tree,
        fuseReadDirectory = readDirectory stat tree,
        fuseGetFileSystemStats = getFileSystemStats
    }

newtype MkStat = MkStat (Fuse.EntryType -> Fuse.FileStat)

mkStat :: UserID -> GroupID -> MkStat
mkStat userId groupId = MkStat $ \entryType -> Fuse.FileStat
    {
        Fuse.statEntryType = entryType,
        Fuse.statFileMode = foldr unionFileModes ownerReadMode
            [ownerExecuteMode, groupReadMode, groupExecuteMode, otherReadMode, otherExecuteMode],
        Fuse.statLinkCount = 1,
        Fuse.statFileOwner = userId,
        Fuse.statFileGroup = groupId,
        Fuse.statSpecialDeviceID = 0,
        Fuse.statFileSize = 1,
        Fuse.statBlocks = 0,
        Fuse.statAccessTime = 0,
        Fuse.statModificationTime = 0,
        Fuse.statStatusChangeTime = 0
    }

data Tagged = Tagged FilePath [FilePath] deriving Show

readTags :: FilePath -> IO Tagged
readTags tagsFile = (Tagged tagsFile . filter (/= "") . lines . decode . unpack) <$> readFile tagsFile

prefixNonEmpty :: a -> [[a]] -> [a]
prefixNonEmpty x = \case
    [] -> []
    xs -> x : intercalate [x] xs

allPaths :: [FilePath] -> [[FilePath]]
allPaths tags = concat (((prefixNonEmpty "and" <$>) <$> permutations <$> subsequences (pathComponents <$> tags)))

singleTagTree :: FilePath -> [FilePath] -> TagTree
singleTagTree tagsFile =
    let dir = takeDirectory tagsFile
    in \case
        [] -> Dir $ Map.singleton (takeFileName dir) $ Link dir
        tag : tags -> Dir $ Map.singleton tag $ singleTagTree tagsFile tags

allTagTrees :: Tagged -> (FilePath, TagTree)
allTagTrees (Tagged dir paths) = (dir, mconcat (singleTagTree dir <$> allPaths paths))

tagsFileName :: FilePath
tagsFileName = "tags"

isTagsFile :: Event -> Bool
isTagsFile e = (takeFileName $ eventPath e) == tagsFileName

handleFileChanges :: Lock -> Var (Map FilePath TagTree) -> Var TagTree -> Event -> IO ()
handleFileChanges lock tagMapHandle tagTreeHandle event =
    let
        handleEvent absTagsFile tagMap =
            let
                add = do
                    contents <- readTags absTagsFile
                    let newTagTree = snd $ allTagTrees contents
                    pure $ Map.insert absTagsFile newTagTree tagMap
            in case event of
                Added _ _ -> add
                Modified _ _ -> add
                Removed _ _ -> pure $ Map.delete absTagsFile tagMap
    in withLock lock $ do
        absTagsFile <- makeAbsolute $ eventPath event
        tagMap <- readVar tagMapHandle
        newTagMap <- handleEvent absTagsFile tagMap
        writeVar tagMapHandle newTagMap
        writeVar tagTreeHandle $ mkDirTree newTagMap

mkDirTree :: Map FilePath TagTree -> TagTree
mkDirTree = mconcat . Map.elems

main :: IO ()
main = withManager $ \mgr -> do
    tagsFiles <- File.find (fileType ==? Directory) (fileType ==? RegularFile &&? fileName ==? tagsFileName) "."
    absTagsFiles <- mapM makeAbsolute tagsFiles
    tagsContents <- mapM readTags absTagsFiles

    let initialTagMap = Map.fromList (allTagTrees <$> tagsContents)

    tagMap <- newVar initialTagMap
    dirTree <- newVar $ mkDirTree initialTagMap
    lock <- newLock
    void $ watchTree mgr "." isTagsFile $ handleFileChanges lock tagMap dirTree

    userId <- getEffectiveUserID
    groupId <- getEffectiveGroupID

    fuseMain (fsOps dirTree $ mkStat userId groupId) Fuse.defaultExceptionHandler
