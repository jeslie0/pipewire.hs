module Pipewire (
    -- * High level API
    PwInstance (..),
    RegistryEvent (..),
    withInstance,
    runInstance,
    quitInstance,
    CoreError (..),
    syncState,
    syncState_,
    readState,

    -- * Mid level bracket API
    withPipewire,
    withMainLoop,
    withContext,
    withCore,

    -- * Protocol
    module Pipewire.Protocol,
    module Pipewire.Enum,

    -- * Core API

    -- ** Initialization
    module Pipewire.CoreAPI.Initialization,

    -- ** Main Loop
    module Pipewire.CoreAPI.MainLoop,

    -- ** Context
    module Pipewire.CoreAPI.Context,

    -- ** Core
    module Pipewire.CoreAPI.Core,

    -- ** Link
    module Pipewire.CoreAPI.Link,
    waitForLink,

    -- ** Loop
    module Pipewire.CoreAPI.Loop,

    -- ** Node
    module Pipewire.CoreAPI.Node,

    -- ** Proxy
    module Pipewire.CoreAPI.Proxy,

    -- ** Registry
    module Pipewire.CoreAPI.Registry,

    -- * Utilities

    -- ** Properties
    module Pipewire.Utilities.Properties,

    -- * SPA

    -- ** Utilities

    -- *** Dictionary
    module Pipewire.SPA.Utilities.Dictionary,

    -- *** Hooks
    module Pipewire.SPA.Utilities.Hooks,

    -- * SPA
    module Pipewire.Stream,

    -- * Helpers
    getHeadersVersion,
    getLibraryVersion,
    cfloatVector,
)
where

import Control.Exception (bracket, bracket_)
import Language.C.Inline qualified as C

import Control.Concurrent (MVar, modifyMVar_, newMVar, readMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Pipewire.CoreAPI.Context (Context, pw_context_connect, pw_context_destroy, pw_context_new)
import Pipewire.CoreAPI.Core (Core, CoreEvents, CoreInfo, DoneHandler, ErrorHandler, InfoHandler, Registry, pw_core_add_listener, pw_core_disconnect, pw_core_get_registry, pw_core_sync, pw_id_core, withCoreEvents)
import Pipewire.CoreAPI.Initialization (pw_deinit, pw_init)
import Pipewire.CoreAPI.Link (Link (..), LinkProperties (..), newLinkProperties, pwLinkEventsFuncs, pw_link_create, withLink, withLinkEvents)
import Pipewire.CoreAPI.Loop (Loop)
import Pipewire.CoreAPI.MainLoop (MainLoop, pw_main_loop_destroy, pw_main_loop_get_loop, pw_main_loop_new, pw_main_loop_quit, pw_main_loop_run, withSignalsHandler)
import Pipewire.CoreAPI.Node (Node, NodeInfoHandler, withNodeEvents, withNodeInfoHandler)
import Pipewire.CoreAPI.Node qualified as PwNode
import Pipewire.CoreAPI.Proxy (PwProxy, pw_proxy_add_object_listener, pw_proxy_destroy, withProxyEvents)
import Pipewire.CoreAPI.Registry (GlobalHandler, GlobalRemoveHandler, pw_registry_add_listener, pw_registry_destroy, withRegistryEvents)
import Pipewire.Enum
import Pipewire.Prelude
import Pipewire.Protocol (PwID (..), PwVersion (..), SeqID (..))
import Pipewire.SPA.Utilities.Dictionary (SpaDict, spaDictLookup, spaDictLookupInt, spaDictRead, spaDictSize, withSpaDict)
import Pipewire.SPA.Utilities.Hooks (SpaHook, withSpaHook)
import Pipewire.Stream (pw_stream_get_node_id)
import Pipewire.Utilities.Properties (PwProperties, pw_properties_get, pw_properties_new, pw_properties_new_dict, pw_properties_set, pw_properties_set_id, pw_properties_set_linger)

C.include "<pipewire/pipewire.h>"

withPipewire :: IO a -> IO a
withPipewire = bracket_ pw_init pw_deinit

-- | Setup a main loop with signal handlers
withMainLoop :: (MainLoop -> IO a) -> IO a
withMainLoop cb = bracket pw_main_loop_new pw_main_loop_destroy withHandler
  where
    withHandler mainLoop = withSignalsHandler mainLoop (cb mainLoop)

withContext :: Loop -> (Context -> IO a) -> IO a
withContext loop = bracket (pw_context_new loop) pw_context_destroy

withCore :: Context -> (Core -> IO a) -> IO a
withCore context = bracket (pw_context_connect context) pw_core_disconnect

getHeadersVersion :: IO Text
getHeadersVersion = ([C.exp| const char*{pw_get_headers_version()} |] :: IO CString) >>= peekCString

getLibraryVersion :: IO Text
getLibraryVersion = ([C.exp| const char*{pw_get_library_version()} |] :: IO CString) >>= peekCString

-- | A pipewire client instance
data PwInstance state = PwInstance
    { stateVar :: MVar state
    , mainLoop :: MainLoop
    , core :: Core
    , registry :: Registry
    , sync :: IORef SeqID
    , errorsVar :: MVar [CoreError]
    }

-- | A pipewire error
data CoreError = CoreError
    { pwid :: PwID
    , code :: Int
    , message :: Text
    }
    deriving (Show)

-- | A registry event
data RegistryEvent = Added PwID Text SpaDict | Removed PwID | ChangedNode PwID SpaDict

-- TODO: handle pw_main_loop error

-- | Run the main loop
runInstance :: PwInstance state -> IO (Maybe (NonEmpty CoreError))
runInstance pwInstance = do
    pw_main_loop_run pwInstance.mainLoop
    getErrors pwInstance

readState :: PwInstance state -> IO state
readState pwInstance = readMVar pwInstance.stateVar

-- | Terminate the main loop, to be called from handlers.
quitInstance :: PwInstance state -> IO ()
quitInstance pwInstance = void $ pw_main_loop_quit pwInstance.mainLoop

-- | Like 'syncState' but throwing an error if there was any pipewire error.
syncState_ :: PwInstance state -> IO state
syncState_ pwInstance =
    syncState pwInstance >>= \case
        Left errs -> mapM_ print errs >> error "pw core failed"
        Right state -> pure state

getErrors :: PwInstance state -> IO (Maybe (NonEmpty CoreError))
getErrors pwInstance = NE.nonEmpty <$> readMVar pwInstance.errorsVar

{- | Ensure all the events have been processed and access the state.
Do not call when the loop is runnning!
-}
syncState :: PwInstance state -> IO (Either (NonEmpty CoreError) state)
syncState pwInstance = do
    -- Write the expected SeqID so that the core handler stop the loop
    writeIORef pwInstance.sync =<< pw_core_sync pwInstance.core pw_id_core
    -- Start the loop
    pw_main_loop_run pwInstance.mainLoop
    -- Call back with the finalized state
    getErrors pwInstance >>= \case
        Just errs -> pure (Left errs)
        Nothing -> Right <$> readState pwInstance

-- | Create a new 'PwInstance' by providing an initial state and a registry update handler.
withInstance :: state -> (PwInstance state -> RegistryEvent -> state -> IO state) -> (PwInstance state -> IO a) -> IO a
withInstance initialState updateState cb =
    withPipewire do
        withMainLoop $ \mainLoop -> do
            loop <- pw_main_loop_get_loop mainLoop
            withContext loop \context -> do
                withCore context \core -> do
                    sync <- newIORef (SeqID 0)
                    errorsVar <- newMVar []
                    withCoreEvents infoHandler (doneHandler mainLoop sync) (errorHandler errorsVar) \coreEvents -> do
                        withSpaHook \coreListener -> do
                            pw_core_add_listener core coreListener coreEvents

                            stateVar <- newMVar initialState
                            registry <- pw_core_get_registry core
                            let pwInstance = PwInstance{stateVar, errorsVar, mainLoop, sync, core, registry}
                            withHandlers pwInstance do
                                cb pwInstance
  where
    -- Setup registry handlers
    withHandlers pwInstance go =
        withSpaHook \registryListener -> do
            withNodeEvents \nodeEvents -> withNodeInfoHandler (nodeInfoHandler pwInstance) nodeEvents do
                withRegistryEvents (handler nodeEvents pwInstance) (removeHandler pwInstance) \registryEvent -> do
                    pw_registry_add_listener pwInstance.registry registryListener registryEvent
                    go

    nodeInfoHandler pwInstance pwid props = do
        spaDictSize props >>= \case
            0 -> pure ()
            _ -> modifyMVar_ pwInstance.stateVar (updateState pwInstance $ ChangedNode pwid props)
    handler nodeEvents pwInstance pwid name _ props = do
        case name of
            "PipeWire:Interface:Node" -> do
                node <- PwNode.bindNode pwInstance.registry pwid
                -- Keep track of node params to get media change
                PwNode.addNodeListener node nodeEvents
            _ -> pure ()
        modifyMVar_ pwInstance.stateVar (updateState pwInstance $ Added pwid name props)
    removeHandler pwInstance pwid = modifyMVar_ pwInstance.stateVar (updateState pwInstance $ Removed pwid)
    infoHandler _pwinfo = pure ()
    errorHandler errorVar pwid _seq' res msg = modifyMVar_ errorVar (\xs -> pure $ CoreError pwid res msg : xs)
    doneHandler mainLoop sync _pwid seqid = do
        pending <- readIORef sync
        when (pending == seqid) do
            void $ pw_main_loop_quit mainLoop

{- |
Do not call when the loop is runnning!
-}
waitForLink :: Link -> PwInstance state -> IO (Maybe (NonEmpty CoreError))
waitForLink pwLink pwInstance = do
    let abort msg = putStrLn msg >> quitInstance pwInstance
        destroyHandler = abort "Destroyed!"
        removedHandler = abort "Proxy Removed!"
        errorHandler res err = abort $ "error: " <> show res <> " " <> show err
    withProxyEvents pwLink.getProxy destroyHandler removedHandler errorHandler do
        let infoHandler pwid state = case state of
                Left err -> abort $ "Link state failed: " <> show err
                Right PW_LINK_STATE_ACTIVE -> do
                    putStrLn "Link is active, quiting the loop!"
                    quitInstance pwInstance
                Right x -> do
                    putStrLn $ "Link state pwid " <> show pwid <> ": " <> show x
                    quitInstance pwInstance

        withSpaHook \spaHook ->
            withLinkEvents infoHandler \ple -> do
                pw_proxy_add_object_listener pwLink.getProxy spaHook (pwLinkEventsFuncs ple)
                putStrLn "Waiting for link..."
                runInstance pwInstance
