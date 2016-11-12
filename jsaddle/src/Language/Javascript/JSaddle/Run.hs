{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.Run
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- |
--
-----------------------------------------------------------------------------

module Language.Javascript.JSaddle.Run (
  -- * Running JSM
    syncPoint
  , syncAfter
  , waitForAnimationFrame
  , nextAnimationFrame
#ifndef ghcjs_HOST_OS
  -- * Functions used to implement JSaddle using JSON messaging
  , runJavaScript
  , AsyncCommand(..)
  , Command(..)
  , Result(..)
  , sendCommand
  , sendLazyCommand
  , sendAsyncCommand
#endif
) where

#ifdef ghcjs_HOST_OS
import Language.Javascript.JSaddle.Types (JSM)
import qualified JavaScript.Web.AnimationFrame as GHCJS
       (waitForAnimationFrame)
#else
import Control.Exception (throwIO)
import Control.Monad (void, forever)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Reader (ask, runReaderT)
import Control.Monad.STM (STM, atomically)
import Control.Concurrent (forkIO)
import Control.Concurrent.STM.TChan
       (tryReadTChan, TChan, readTChan, writeTChan, newTChanIO)
import Control.Concurrent.STM.TVar
       (writeTVar, readTVar, readTVarIO, modifyTVar, newTVarIO)
import Control.Concurrent.MVar
       (MVar, MVar, putMVar, takeMVar, newEmptyMVar)

import Data.Monoid ((<>))
import qualified Data.Text as T (unpack)
import qualified Data.Map as M (lookup, delete, insert, empty)
import Data.Time.Clock (getCurrentTime,diffUTCTime)

import Language.Javascript.JSaddle.Types
       (Command(..), AsyncCommand(..), Result(..), JSContextRef(..), JSVal(..),
        Object(..), JSValueReceived(..), JSM(..), Batch(..), JSValueForSend(..))
import Language.Javascript.JSaddle.Exception (JSException(..))
import Language.Javascript.JSaddle.Native (wrapJSVal)
#endif

-- | Forces execution of pending asyncronous code
syncPoint :: JSM ()
#ifdef ghcjs_HOST_OS
syncPoint = return ()
#else
syncPoint = void $ sendCommand Sync
#endif

-- | Forces execution of pending asyncronous code after performing `f`
syncAfter :: JSM a -> JSM a
#ifdef ghcjs_HOST_OS
syncAfter = id
#else
syncAfter f = do
    result <- f
    syncPoint
    return result
#endif

-- | On GHCJS this is 'JavaScript.Web.AnimationFrame.waitForAnimationFrame'.
--   On GHC it will delay the execution of the current batch of asynchronous
--   command when they are sent to JavaScript.  It will not delay the Haskell
--   code execution.  The time returned will be based on the Haskell clock
--   (not the JavaScript clock).
waitForAnimationFrame :: JSM Double
#ifdef ghcjs_HOST_OS
waitForAnimationFrame = GHCJS.waitForAnimationFrame
#else
waitForAnimationFrame = do
    -- We can't get the timestamp from requestAnimationFrame so this will have to do
    start <- startTime <$> JSM ask
    now <- liftIO getCurrentTime
    void $ sendLazyCommand SyncWithAnimationFrame
    return $ realToFrac (diffUTCTime now start)
#endif

-- | Tries to executes the given code in the next animation frame callback.
--   Avoid synchronous opperations where possible.
nextAnimationFrame :: (Double -> JSM a) -> JSM a
nextAnimationFrame f = do
    t <- waitForAnimationFrame
    syncAfter (f t)

#ifndef ghcjs_HOST_OS
sendCommand :: Command -> JSM Result
sendCommand cmd = do
    s <- doSendCommand <$> JSM ask
    liftIO $ s cmd

sendLazyCommand :: (JSValueForSend -> AsyncCommand) -> JSM JSVal
sendLazyCommand cmd = do
    nextRefTVar <- nextRef <$> JSM ask
    n <- liftIO . atomically $ do
        n <- subtract 1 <$> readTVar nextRefTVar
        writeTVar nextRefTVar n
        return n
    s <- doSendAsyncCommand <$> JSM ask
    liftIO $ s (cmd $ JSValueForSend n)
    wrapJSVal (JSValueReceived n)

sendAsyncCommand :: AsyncCommand -> JSM ()
sendAsyncCommand cmd = do
    s <- doSendAsyncCommand <$> JSM ask
    liftIO $ s cmd

runJavaScript :: (Batch -> IO ()) -> JSM () -> IO (Result -> IO (), IO ())
runJavaScript sendBatch entryPoint = do
    startTime' <- getCurrentTime
    recvChan <- newTChanIO
    commandChan <- newTChanIO
    callbacks <- newTVarIO M.empty
    nextRef' <- newTVarIO 0
    let ctx = JSContextRef {
        startTime = startTime'
      , doSendCommand = \cmd -> do
            result <- newEmptyMVar
            atomically $ writeTChan commandChan (Right (cmd, result))
            takeMVar result >>= \case
                (ThrowJSValue (JSValueReceived v)) -> throwIO $ JSException (JSVal v)
                r -> return r
      , doSendAsyncCommand = atomically . writeTChan commandChan . Left
      , addCallback = \(Object (JSVal val)) cb -> atomically $ modifyTVar callbacks (M.insert val cb)
      , freeCallback = \(Object (JSVal val)) -> atomically $ modifyTVar callbacks (M.delete val)
      , nextRef = nextRef'
      }
    let processResult = \case
            (ProtocolError err) -> error $ "Protocol error : " <> T.unpack err
            (Callback f this a) -> do
                f'@(JSVal fNumber) <- runReaderT (unJSM $ wrapJSVal f) ctx
                this' <- runReaderT  (unJSM $ wrapJSVal this) ctx
                args <- runReaderT (unJSM $ mapM wrapJSVal a) ctx
                (M.lookup fNumber <$> liftIO (readTVarIO callbacks)) >>= \case
                    Nothing -> liftIO $ putStrLn "Callback called after it was freed"
                    Just cb -> void . forkIO $ runReaderT (unJSM $ cb f' this' args) ctx
            m                   -> atomically $ writeTChan recvChan m
    _ <- forkIO . forever $ readBatch commandChan >>= \case
            (batch, Just resultMVar) -> do
                sendBatch batch
                atomically (readTChan recvChan) >>= putMVar resultMVar
            (batch, Nothing) -> do
                sendBatch batch
                atomically (readTChan recvChan) >>= \case
                    SyncResult -> return ()
                    ThrowJSValue e -> atomically (discardToSyncPoint commandChan) >>= (`putMVar` ThrowJSValue e)
                    _ -> error "Unexpected result processing batch"
                return ()
    return (processResult, runReaderT (unJSM entryPoint) ctx)
  where
    readBatch :: TChan (Either AsyncCommand (Command, MVar Result)) -> IO (Batch, Maybe (MVar Result))
    readBatch chan = do
        first <- atomically $ readTChan chan -- We want at least one command to send
        loop first []
      where
        loop (Left asyncCmd@(SyncWithAnimationFrame _)) asyncCmds =
            atomically (readTChan chan) >>= \cmd -> loopAnimation cmd (asyncCmd:asyncCmds)
        loop (Right (cmd, resultMVar)) asyncCmds =
            return (Batch (reverse asyncCmds) cmd False, Just resultMVar)
        loop (Left asyncCmd) asyncCmds' = do
            let asyncCmds = asyncCmd:asyncCmds'
            atomically (tryReadTChan chan) >>= \case
                Nothing -> return (Batch (reverse asyncCmds) Sync False, Nothing)
                Just cmd -> loop cmd asyncCmds
        -- When we have seen a SyncWithAnimationFrame command only a synchronous command should end the batch
        loopAnimation (Right (cmd, resultMVar)) asyncCmds =
            return (Batch (reverse asyncCmds) cmd True, Just resultMVar)
        loopAnimation (Left asyncCmd) asyncCmds =
            atomically (readTChan chan) >>= \cmd -> loopAnimation cmd (asyncCmd:asyncCmds)
    discardToSyncPoint :: TChan (Either AsyncCommand (Command, MVar Result)) -> STM (MVar Result)
    discardToSyncPoint chan =
        readTChan chan >>= \case
            Right (_, resultMVar) -> return resultMVar
            _                     -> discardToSyncPoint chan
#endif