module Caches.Local.Downloading where

import           Configuration                (carthageBuildDirectory,
                                               carthageBuildDirectoryForPlatform)
import           Control.Monad.Except
import           Control.Monad.Trans.Resource (runResourceT)
import qualified Data.ByteString.Lazy         as LBS
import           Data.Carthage.TargetPlatform
import qualified Data.Conduit                 as C (($$))
import qualified Data.Conduit.Binary          as C (sinkLbs, sourceFile)
import           Data.Romefile
import           System.Directory
import           System.FilePath
import           Types                        hiding (version)

import           Caches.Common
import           Control.Monad.Reader         (ReaderT, ask)
import           Data.Either
import           Data.Monoid                  ((<>))
import           Utils
import           Xcode.DWARF



-- | Retrieves a Framework from a local cache
getFrameworkFromLocalCache :: MonadIO m
                           => FilePath -- ^ The cache definition
                           -> CachePrefix -- ^ A prefix for folders at top level in the cache.
                           -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the Framework in the cache
                           -> FrameworkVersion -- ^ The `FrameworkVersion` indentifying the Framework
                           -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                           -> ExceptT String m LBS.ByteString
getFrameworkFromLocalCache lCacheDir
                           (CachePrefix prefix)
                           reverseRomeMap
                           (FrameworkVersion f@(FrameworkName fwn) version)
                           platform = do
  frameworkExistsInLocalCache <- liftIO . doesFileExist $ frameworkLocalCachePath prefix
  if frameworkExistsInLocalCache
    then liftIO . runResourceT $ C.sourceFile (frameworkLocalCachePath prefix) C.$$ C.sinkLbs
    else throwError $ "Error: could not find " <> fwn <> " in local cache at : " <> frameworkLocalCachePath prefix
  where
    frameworkLocalCachePath cPrefix = lCacheDir </> cPrefix </> remoteFrameworkUploadPath
    remoteFrameworkUploadPath = remoteFrameworkPath platform reverseRomeMap f version



-- | Retrieves a .version file from a local cache
getVersionFileFromLocalCache :: MonadIO m
                             => FilePath -- ^ The cache definition
                             -> CachePrefix -- ^ A prefix for folders at top level in the cache.
                             -> GitRepoNameAndVersion -- ^ The `GitRepoNameAndVersion` used to indentify the .version file
                             -> ExceptT String m LBS.ByteString
getVersionFileFromLocalCache lCacheDir
                             (CachePrefix prefix)
                             gitRepoNameAndVersion = do
  versionFileExistsInLocalCache <- liftIO . doesFileExist $ versionFileLocalCachePath

  if versionFileExistsInLocalCache
    then liftIO . runResourceT $ C.sourceFile versionFileLocalCachePath C.$$ C.sinkLbs
    else throwError $ "Error: could not find " <> versionFileName <> " in local cache at : " <> versionFileLocalCachePath
  where
    versionFileName = versionFileNameForGitRepoName $ fst gitRepoNameAndVersion
    versionFileRemotePath = remoteVersionFilePath gitRepoNameAndVersion
    versionFileLocalCachePath = lCacheDir </> prefix </>versionFileRemotePath



-- | Retrieves a bcsymbolmap from a local cache
getBcsymbolmapFromLocalCache :: MonadIO m
                             => FilePath -- ^ The cache definition
                             -> CachePrefix -- ^ A prefix for folders at top level in the cache.
                             -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
                             -> FrameworkVersion -- ^ The `FrameworkVersion` indentifying the dSYM
                             -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                             -> DwarfUUID -- ^ The UUID of the bcsymbolmap
                             -> ExceptT String m LBS.ByteString
getBcsymbolmapFromLocalCache lCacheDir
                             (CachePrefix prefix)
                             reverseRomeMap
                             (FrameworkVersion f@(FrameworkName fwn) version)
                             platform
                             dwarfUUID = do
  let finalBcsymbolmapLocalPath = bcsymbolmapLocalCachePath prefix
  bcSymbolmapExistsInLocalCache <- liftIO . doesFileExist $ finalBcsymbolmapLocalPath
  if bcSymbolmapExistsInLocalCache
    then liftIO . runResourceT $ C.sourceFile finalBcsymbolmapLocalPath C.$$ C.sinkLbs
    else throwError $ "Error: could not find " <> bcsymbolmapName <> " in local cache at : " <> finalBcsymbolmapLocalPath
  where
    remoteBcsymbolmapUploadPath = remoteBcsymbolmapPath dwarfUUID platform reverseRomeMap f version
    bcsymbolmapLocalCachePath cPrefix = lCacheDir </> cPrefix </> remoteBcsymbolmapUploadPath
    bcsymbolmapName = fwn <> "." <> bcsymbolmapNameFrom dwarfUUID



-- | Retrieves a dSYM from a local cache
getDSYMFromLocalCache :: MonadIO m
                      => FilePath -- ^ The cache definition
                      -> CachePrefix -- ^ A prefix for folders at top level in the cache.
                      -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
                      -> FrameworkVersion -- ^ The `FrameworkVersion` indentifying the dSYM
                      -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                      -> ExceptT String m LBS.ByteString
getDSYMFromLocalCache lCacheDir
                      (CachePrefix prefix)
                      reverseRomeMap
                      (FrameworkVersion f@(FrameworkName fwn) version)
                      platform = do
  let finalDSYMLocalPath = dSYMLocalCachePath prefix
  dSYMExistsInLocalCache <- liftIO . doesFileExist $ finalDSYMLocalPath
  if dSYMExistsInLocalCache
    then liftIO . runResourceT $ C.sourceFile finalDSYMLocalPath C.$$ C.sinkLbs
    else throwError $ "Error: could not find " <> dSYMName <> " in local cache at : " <> finalDSYMLocalPath
  where
    dSYMLocalCachePath cPrefix = lCacheDir </> cPrefix </> remotedSYMUploadPath
    remotedSYMUploadPath = remoteDsymPath platform reverseRomeMap f version
    dSYMName = fwn <> ".dSYM"



-- | Retrieves a bcsymbolmap file from a local cache and unzips the contents
getAndUnzipBcsymbolmapFromLocalCache :: MonadIO m
                                     => FilePath -- ^ The cache definition
                                     -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
                                     -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
                                     -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                                     -> DwarfUUID
                                     -> ExceptT String (ReaderT (CachePrefix, Bool) m) ()
getAndUnzipBcsymbolmapFromLocalCache lCacheDir
                                     reverseRomeMap
                                     fVersion@(FrameworkVersion f@(FrameworkName fwn) version)
                                     platform
                                     dwarfUUID = do
  (cachePrefix@(CachePrefix prefix), verbose) <- ask
  let sayFunc = if verbose then sayLnWithTime else sayLn
  let symbolmapName = fwn <> "." <> bcsymbolmapNameFrom dwarfUUID
  binary <- getBcsymbolmapFromLocalCache lCacheDir cachePrefix reverseRomeMap fVersion platform dwarfUUID
  sayFunc $ "Found " <> symbolmapName <> " in local cache at: " <> frameworkLocalCachePath prefix
  deleteFile (bcsybolmapPath dwarfUUID) verbose
  unzipBinary binary symbolmapName (bcsymbolmapZipName dwarfUUID) verbose
  where
    frameworkLocalCachePath cPrefix = lCacheDir </> cPrefix </> remoteFrameworkUploadPath
    remoteFrameworkUploadPath = remoteFrameworkPath platform reverseRomeMap f version
    bcsymbolmapZipName d = bcsymbolmapArchiveName d version
    bcsybolmapPath d = platformBuildDirectory </> bcsymbolmapNameFrom d
    platformBuildDirectory = carthageBuildDirectoryForPlatform platform



-- | Retrieves all the bcsymbolmap files from a local cache and unzip the contents
getAndUnzipBcsymbolmapsFromLocalCache :: MonadIO m
                                      => FilePath -- ^ The cache definition
                                      -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
                                      -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
                                      -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                                      -> ExceptT String (ReaderT (CachePrefix, Bool) m) ()
getAndUnzipBcsymbolmapsFromLocalCache lCacheDir
                                      reverseRomeMap
                                      fVersion@(FrameworkVersion f@(FrameworkName fwn) _)
                                      platform = do
  (_, verbose) <- ask
  let sayFunc = if verbose then sayLnWithTime else sayLn

  dwarfUUIDs <- dwarfUUIDsFrom (frameworkDirectory </> fwn)
  mapM_ (\dwarfUUID ->
    getAndUnzipBcsymbolmapFromLocalCache lCacheDir reverseRomeMap fVersion platform dwarfUUID `catchError` sayFunc)
    dwarfUUIDs
  where
    frameworkNameWithFrameworkExtension = appendFrameworkExtensionTo f
    platformBuildDirectory = carthageBuildDirectoryForPlatform platform
    frameworkDirectory = platformBuildDirectory </> frameworkNameWithFrameworkExtension



-- | Retrieves all the bcsymbolmap files from a local cache and unzip the contents
getAndUnzipBcsymbolmapsFromLocalCache' :: MonadIO m
                                       => FilePath -- ^ The cache definition
                                       -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
                                       -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
                                       -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                                       -> ExceptT DWARFOperationError (ReaderT (CachePrefix, Bool) m) ()
getAndUnzipBcsymbolmapsFromLocalCache' lCacheDir
                                       reverseRomeMap
                                       fVersion@(FrameworkVersion f@(FrameworkName fwn) _)
                                       platform = do

  dwarfUUIDs <- withExceptT (const ErrorGettingDwarfUUIDs) $ dwarfUUIDsFrom (frameworkDirectory </> fwn)
  eitherDwarfUUIDsOrSucces <- forM dwarfUUIDs
    (\dwarfUUID ->
      lift $ runExceptT (withExceptT
        (\e -> (dwarfUUID, e)) $
          getAndUnzipBcsymbolmapFromLocalCache lCacheDir reverseRomeMap fVersion platform dwarfUUID))

  let failedUUIDsAndErrors = lefts eitherDwarfUUIDsOrSucces
  unless (null failedUUIDsAndErrors) $
      throwError $ FailedDwarfUUIDs failedUUIDsAndErrors

  where
    frameworkNameWithFrameworkExtension = appendFrameworkExtensionTo f
    platformBuildDirectory = carthageBuildDirectoryForPlatform platform
    frameworkDirectory = platformBuildDirectory </> frameworkNameWithFrameworkExtension



-- | Retrieves a Frameworks and the corresponding dSYMs from a local cache for given `TargetPlatform`s, then unzips the contents
getAndUnzipFrameworksAndArtifactsFromLocalCache :: MonadIO m
                                                => FilePath -- ^ The cache definition
                                                -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the Framework in the cache
                                                -> [FrameworkVersion] -- ^ The a list of `FrameworkVersion` identifying the Frameworks and dSYMs
                                                -> [TargetPlatform] -- ^ A list of `TargetPlatform`s to limit the operation to
                                                -> [ExceptT String (ReaderT (CachePrefix, Bool) m) ()]
getAndUnzipFrameworksAndArtifactsFromLocalCache lCacheDir
                                                reverseRomeMap
                                                fvs
                                                platforms =
  concatMap getAndUnzipFramework platforms
    <> concatMap getAndUnzipBcsymbolmaps platforms
    <> concatMap getAndUnzipDSYM platforms
  where
  getAndUnzipFramework    = mapM (getAndUnzipFrameworkFromLocalCache lCacheDir reverseRomeMap) fvs
  getAndUnzipBcsymbolmaps = mapM (getAndUnzipBcsymbolmapsFromLocalCache lCacheDir reverseRomeMap) fvs
  getAndUnzipDSYM         = mapM (getAndUnzipDSYMFromLocalCache lCacheDir reverseRomeMap) fvs



-- | Retrieves a Framework from a local cache and unzip the contents
getAndUnzipFrameworkFromLocalCache :: MonadIO m
                                   => FilePath -- ^ The cache definition
                                   -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the Framework in the cache
                                   -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
                                   -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                                   -> ExceptT String (ReaderT (CachePrefix , Bool) m) ()
getAndUnzipFrameworkFromLocalCache lCacheDir
                                   reverseRomeMap
                                   fVersion@(FrameworkVersion f@(FrameworkName fwn) version)
                                   platform = do
  (cachePrefix@(CachePrefix prefix), verbose) <- ask
  let sayFunc = if verbose then sayLnWithTime else sayLn
  binary <- getFrameworkFromLocalCache lCacheDir cachePrefix reverseRomeMap fVersion platform
  sayFunc $ "Found " <> fwn <> " in local cache at: " <> frameworkLocalCachePath prefix
  deleteFrameworkDirectory fVersion platform verbose
  unzipBinary binary fwn frameworkZipName verbose <* makeExecutable platform f
  where
    frameworkLocalCachePath cPrefix = lCacheDir </> cPrefix </> remoteFrameworkUploadPath
    remoteFrameworkUploadPath = remoteFrameworkPath platform reverseRomeMap f version
    frameworkZipName = frameworkArchiveName f version




-- | Retrieves a dSYM from a local cache yy and unzip the contents
getAndUnzipDSYMFromLocalCache :: MonadIO m
                              => FilePath -- ^ The cache definition
                              -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
                              -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
                              -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
                              -> ExceptT String (ReaderT (CachePrefix, Bool) m) ()
getAndUnzipDSYMFromLocalCache lCacheDir
                              reverseRomeMap
                              fVersion@(FrameworkVersion f@(FrameworkName fwn) version)
                              platform = do
  (cachePrefix@(CachePrefix prefix), verbose) <- ask
  let finalDSYMLocalPath = dSYMLocalCachePath prefix
  let sayFunc = if verbose then sayLnWithTime else sayLn
  binary <- getDSYMFromLocalCache lCacheDir cachePrefix reverseRomeMap fVersion platform
  sayFunc $ "Found " <> dSYMName <> " in local cache at: " <> finalDSYMLocalPath
  deleteDSYMDirectory fVersion platform verbose
  unzipBinary binary fwn dSYMZipName verbose <* makeExecutable platform f
  where
    dSYMLocalCachePath cPrefix = lCacheDir </> cPrefix </> remotedSYMUploadPath
    remotedSYMUploadPath = remoteDsymPath platform reverseRomeMap f version
    dSYMZipName = dSYMArchiveName f version
    dSYMName = fwn <> ".dSYM"



-- | Gets a multiple .version file from a local cache and saves them to the appropriate location.
getAndSaveVersionFilesFromLocalCache :: MonadIO m
                                     => FilePath -- ^ The cache definition.
                                     -> [GitRepoNameAndVersion] -- ^ A list of `GitRepoNameAndVersion` identifying the .version files
                                     -> [ExceptT String (ReaderT (CachePrefix, Bool) m) ()]
getAndSaveVersionFilesFromLocalCache lCacheDir =
    map (getAndSaveVersionFileFromLocalCache lCacheDir)



-- | Gets a .version file from a local cache and copies it to the approrpiate location.
getAndSaveVersionFileFromLocalCache :: MonadIO m
                                    => FilePath -- ^ The cache definition.
                                    -> GitRepoNameAndVersion -- ^ The `GitRepoNameAndVersion` identifying the .version file
                                    -> ExceptT String (ReaderT (CachePrefix, Bool) m) ()
getAndSaveVersionFileFromLocalCache lCacheDir gitRepoNameAndVersion = do
  (cachePrefix@(CachePrefix prefix), verbose) <- ask
  let finalVersionFileLocalCachePath = versionFileLocalCachePath prefix
  let sayFunc = if verbose then sayLnWithTime else sayLn
  versionFileBinary <- getVersionFileFromLocalCache lCacheDir cachePrefix gitRepoNameAndVersion
  sayFunc $ "Found " <> versionFileName <> " in local cache at: " <> finalVersionFileLocalCachePath
  saveBinaryToFile versionFileBinary versionFileLocalPath
  sayFunc $ "Copied " <> versionFileName <> " to: " <> versionFileLocalPath

  where
   versionFileName = versionFileNameForGitRepoName $ fst gitRepoNameAndVersion
   versionFileRemotePath = remoteVersionFilePath gitRepoNameAndVersion
   versionFileLocalPath = carthageBuildDirectory </> versionFileName
   versionFileLocalCachePath cPrefix = lCacheDir </> cPrefix </> versionFileRemotePath



