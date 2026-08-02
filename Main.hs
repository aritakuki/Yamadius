{- Copyright 2005 Hideyuki Tanaka & Takayuki Muranushi
  This program is distributed under the terms of the GNU General Public License.

   NOTE
 This project meant to list up, not to solve, many possible problems that will appear
 while writing a game in Haskell.
 Only nushio is responsible to the unreadability of these codes.
-}

{-# LANGUAGE ForeignFunctionInterface #-}

module Main (main) where

import           Control.Exception  (SomeException (..), catch)
import           Control.Monad      (mplus, zipWithM_)
import qualified Codec.Picture       as JP
import           Control.Applicative
import           Data.Complex
import           Data.IORef
import           Data.List
import           Data.Maybe
import           Graphics.UI.GLUT   hiding (position)
import           System.Directory   (createDirectoryIfMissing, doesFileExist)
import           System.Environment (getArgs, getEnv, lookupEnv)
import           System.Exit        (exitSuccess)
import qualified Graphics.Rendering.OpenGL.GL    as GL
import qualified Data.Vector.Storable             as VS
import           Data.Array                      (Array, array, (!))
import           Data.Complex
import           Data.List
import           Data.Maybe
import           Graphics.Rendering.OpenGL.GLU
import           Graphics.UI.GLUT                hiding (Bitmap, position)
import           Unsafe.Coerce
import           Foreign
import           Foreign.C.Types
import           Foreign.Ptr

import qualified Data.Map                        as Map
import qualified Data.Set                        as Set
import           System.Random

import           Demo               (ReplayInfo (..), demoData)
import           Game               (isGameover, render, update, playSe)
import           Monadius
import           Recorder
--import           Util               (intToGLdouble, padding, putDebugStrLn)
import           Util

import Control.Monad ( when, unless )
import Sound.ALUT
import System.Exit ( exitFailure )
import System.IO ( hPutStrLn, stderr )
import Control.Concurrent
import Control.Monad.Fix (fix)

foreign import ccall "_Z13initEffekseerii" c_initEffeksser :: CInt -> CInt -> IO ()
foreign import ccall "_Z15finishEffekseerv" c_finishEffeksser :: IO ()
foreign import ccall "_Z13procEffekseerv" c_procEffeksser :: IO ()
foreign import ccall "_Z16restartEffekseeri" c_restartEffeksser :: CInt -> IO ()
foreign import ccall "setEffekseerPlayerPosition" c_setEffeksserPlayerPosition :: CFloat -> CFloat -> IO ()
foreign import ccall "initEglRenderer" c_initEglRenderer :: CInt -> CInt -> IO CInt
foreign import ccall "finishEglRenderer" c_finishEglRenderer :: IO ()
foreign import ccall "presentMonadiusFrame" c_presentMonadiusFrame :: IO ()

presentFrame :: IO ()
presentFrame = do
  eglMode <- isJust <$> lookupEnv "MONADIUS_EGL"
  if eglMode then c_presentMonadiusFrame else swapBuffers

reportColabStatus :: String -> IO ()
reportColabStatus value = do
  statusFile <- lookupEnv "MONADIUS_STATUS_FILE"
  case statusFile of
    Nothing       -> return ()
    Just filename -> writeFile filename value
      `catch` (\(SomeException _) -> return ())

data GlobalVariables = GlobalVariables{
  saveState :: (Int,Int) ,isCheat :: Bool, demoIndex :: Int,
  -- | 'recorderMode' means general gamemode that user wants,
  -- 'mode' of a recorder means current gamemode.
  -- two are different when temporal demo replays.
  recorderMode :: RecorderMode,
  playbackKeys :: [[Key]],playbackSaveState :: (Int,Int),playBackName :: Maybe String,
  recordSaveState :: (Int,Int),saveHiScore :: Int
  }

replayFileExtension :: String
replayFileExtension = ".replay"

presentationMode :: Bool
presentationMode = True


loadReplay :: String-> IO ReplayInfo
loadReplay filename = readFile filename >>= (return . read)

-- テクスチャをファイルから読み込む
-- 何をやっているのか未だによくわからない
-- FreeGameのサンプルをちょっといじったもの
loadTextureFromFile :: FilePath -> IO GL.TextureObject
loadTextureFromFile path = do
    decoded <- either error return =<< JP.readImage path
    let source = JP.convertRGBA8 decoded
        content = JP.generateImage (\x y -> JP.pixelAt source x (JP.imageHeight source - y - 1))
                                   (JP.imageWidth source) (JP.imageHeight source) :: JP.Image JP.PixelRGBA8
        width = JP.imageWidth content
        height = JP.imageHeight content
    [tex] <- GL.genObjectNames 1
    GL.textureBinding GL.Texture2D GL.$= Just tex
    GL.textureFilter Texture2D $= ((Nearest, Nothing), Nearest)
    VS.unsafeWith (JP.imageData content)
        $ GL.texImage2D Texture2D GL.NoProxy 0 GL.RGBA8 (GL.TextureSize2D (gsizei width) (gsizei height)) 0
        . GL.PixelData GL.RGBA GL.UnsignedByte
    return tex

gsizei :: Int -> GL.GLsizei
{-# INLINE gsizei #-}
gsizei x = unsafeCoerce x

main :: IO ()
main = do
  args <- getArgs
  putDebugStrLn $ show args
  eglMode <- isJust <$> lookupEnv "MONADIUS_EGL"
  -- Colab's runner supplies a tiny Xvfb solely so freeglut can initialise its
  -- built-in stroke-font data.  The actual rendering context is still the
  -- NVIDIA EGL pbuffer created below; no GLUT window or GLX context is made.
  _ <- getArgsAndInitialize
  keystate <- newIORef []
  -- In a normal desktop run GLUT owns the keyboard.  In Colab there is no
  -- desktop window for the browser to focus, so the small local bridge writes
  -- the currently-held keys to this file instead.  Keeping it optional means
  -- the existing native keyboard path remains unchanged.
  externalInputFile <- lookupEnv "MONADIUS_INPUT_FILE"

  withProgNameAndArgs runALUT $ \_ _ -> do
      sounds <- loadSounds
      ses <- loadSEs

      (recMode,keys,rss,repName) <- if isJust $ getReplayFilename args then do
          ReplayInfo (ss,keystr) <- (loadReplay . fromJust . getReplayFilename) args
          return (Playback,decode keystr,ss,Just $ (simplify . fromJust . getReplayFilename) args)
        else if "-r" `elem` args then do
            return (Play,[],(1,0),Nothing)
          else
            return (Record,[],(1,0),Nothing)

      backgroundMusic (bgm0 sounds)

      let initialWidth = 1280
          initialHeight = 1040
      let setupScene = do
            c_initEffeksser 640 480
            shieldTextures <- mapM loadTextureFromFile
              [ "Resources/force-field-frame-0.png"
              , "Resources/force-field-frame-1.png"
              , "Resources/force-field-frame-2.png"
              , "Resources/force-field-frame-3.png"
              ]
            GL.blend $= GL.Enabled
            GL.blendFunc $= (GL.SrcAlpha, GL.OneMinusSrcAlpha)
            newIORef (openingProc shieldTextures ses sounds 0 0 GlobalVariables{saveState = (1,0) ,isCheat = False,
              recorderMode=recMode,playbackKeys=keys,playbackSaveState = rss,recordSaveState=(1,0),demoIndex=0,
              playBackName=repName,saveHiScore=0} keystate)

      if eglMode then do
        ready <- c_initEglRenderer (fromIntegral initialWidth) (fromIntegral initialHeight)
        unless (ready /= 0) $ error "Could not create the NVIDIA EGL renderer"
        cp <- setupScene
        initMatrixSize (Size initialWidth initialHeight)
        let loop = do
              dispProc externalInputFile keystate cp
              threadDelay 16000
              loop
        loop
        c_finishEffeksser
        c_finishEglRenderer
       else do
        Size screenWidth screenHeight <- get screenSize
        initialWindowSize Graphics.UI.GLUT.$= Size initialWidth initialHeight
        initialWindowPosition Graphics.UI.GLUT.$= Position
          ((screenWidth - initialWidth) `div` 2)
          ((screenHeight - initialHeight) `div` 2)
        initialDisplayMode Graphics.UI.GLUT.$= [RGBAMode,DoubleBuffered]
        wnd <- createWindow "Monadius"
        cp <- setupScene
        curwnd <- if "-f" `elem` args then do
          gameModeCapabilities Graphics.UI.GLUT.$= [
              Where' GameModeWidth IsLessThan 650,
              Where' GameModeHeight IsLessThan 500]
          displayCallback Graphics.UI.GLUT.$= dispProc externalInputFile keystate cp
          (wnd2,_) <- enterGameMode
          destroyWindow wnd
          return wnd2
         else return wnd
        displayCallback Graphics.UI.GLUT.$= dispProc externalInputFile keystate cp
        keyboardMouseCallback Graphics.UI.GLUT.$= Just (keyProc keystate)
        reshapeCallback Graphics.UI.GLUT.$= Just (const initMatrix)
        addTimerCallback 16 (timerProc (dispProc externalInputFile keystate cp))
        initMatrix
        mainLoop
        destroyWindow curwnd
        c_finishEffeksser

      `catch` (\(SomeException err) ->
        hPutStrLn stderr ("Monadius terminated during initialisation: " ++ show err))

      where
        getReplayFilename [] = Nothing
        getReplayFilename a = (Just . head . candidates) a

        candidates args = filter (replayFileExtension `isSuffixOf`) args

        simplify = (removesuffix . removedir)

        removedir str = if '\\' `elem` str || '/' `elem` str then (removedir . tail) str else str
        removesuffix str = if '.' `elem` str then (removesuffix . init) str else str

exitLoop :: IO a
exitLoop = exitSuccess

initMatrix :: IO ()
initMatrix = get windowSize >>= initMatrixSize

initMatrixSize :: Size -> IO ()
initMatrixSize (Size width height) = do
  viewport Graphics.UI.GLUT.$= (Position 0 0,Size width height)
  matrixMode Graphics.UI.GLUT.$= Projection
  loadIdentity
  perspective 30.0 (fromIntegral width / fromIntegral height) 600 1400
  lookAt (Vertex3 0 0 (927 :: GLdouble)) (Vertex3 0 0 (0 :: GLdouble)) (Vector3 0 1 (0 :: GLdouble))

dispProc :: Maybe FilePath -> IORef [Key] -> IORef (IO Scene) -> IO ()
dispProc externalInputFile keystate cp = do
  refreshExternalKeys externalInputFile keystate
  m <- readIORef cp
  Scene next <- m
  writeIORef cp next

-- | Read the key set maintained by the Colab browser bridge.  The file holds
-- whitespace-separated tokens such as "left up a"; it is deliberately a
-- tiny, dependency-free protocol so the game itself needs no web libraries.
refreshExternalKeys :: Maybe FilePath -> IORef [Key] -> IO ()
refreshExternalKeys Nothing _ = return ()
refreshExternalKeys (Just filename) keystate = do
  exists <- doesFileExist filename
  when exists $ do
    contents <- readFile filename `catch` (\(SomeException _) -> return "")
    writeIORef keystate (nub (mapMaybe externalKey (words contents)))
  where
    externalKey token = case token of
      "left"  -> Just (SpecialKey KeyLeft)
      "right" -> Just (SpecialKey KeyRight)
      "up"    -> Just (SpecialKey KeyUp)
      "down"  -> Just (SpecialKey KeyDown)
      "space" -> Just (Char ' ')
      "a"     -> Just (Char 'a')
      "f"     -> Just (Char 'f')
      "g"     -> Just (Char 'g')
      [digit] | digit >= '0' && digit <= '9' -> Just (Char digit)
      _ -> Nothing

-- | Scene is something that does some IO,
-- then returns the Scene that are to be executed in next frame.
newtype Scene = Scene (IO Scene)

openingProc :: [GL.TextureObject] -> SEs -> Sounds -> Int -> Int -> GlobalVariables -> IORef [Key] -> IO Scene
openingProc shieldTextures ses sounds clock menuCursor vars ks = do
  if recorderMode vars == Playback then gameStart (fst $ playbackSaveState vars) (snd $ playbackSaveState vars) (isCheat vars) Playback vars else do
  if clock > demoStartTime then do demoStart vars else do

  keystate <- readIORef ks
  reportColabStatus $ "scene=title clock=" ++ show clock ++ " keys=" ++ show keystate
  clear [ColorBuffer,DepthBuffer]
  matrixMode Graphics.UI.GLUT.$= Modelview 0
  loadIdentity
  if clock < drawCompleteTime then color $ Color3 (0 :: GLdouble) 0.2 0.8
    else color $ Color3 (0+shine clock :: GLdouble) (0.2+shine clock) (0.8+shine clock)
  preservingMatrix $ do
    translate (Vector3 0 (120 :: GLdouble) 0)
    scale 1.05 1 (1 :: GLdouble)
    mapM_ (renderPrimitive LineStrip . renderVertices2D.delayVertices clock) [lambdaLfoot,lambdaRfoot]
  color $ Color3 (1.0 :: GLdouble) 1.0 1.0
  preservingMatrix $ do
    translate $ Vector3 (-195 :: GLdouble) (130) 0
    scale (0.73 :: GLdouble) 0.56 0.56
--    renderStringGrad Roman 0 "Monadius"
    renderStringGrad Roman 0 "Yamadius"
  preservingMatrix $ do
    if menuCursor==0 then color $ Color3 (1.0 :: GLdouble) 1.0 0 else color $ Color3 (1.0 :: GLdouble) 1.0 1.0
    translate $ Vector3 (-230 :: GLdouble) (-200) 0
    scale (0.2 :: GLdouble) 0.2 0.3
    renderStringGrad Roman 60 $ (if menuCursor==0 then ">" else " ") ++ "New Game"
  preservingMatrix $ do
    if menuCursor==1 then color $ Color3 (1.0 :: GLdouble) 1.0 0 else color $ Color3 (1.0 :: GLdouble) 1.0 1.0
    translate $ Vector3 (70 :: GLdouble) (-200) 0
    scale (0.2 :: GLdouble) 0.2 0.3
    renderStringGrad Roman 60 $ (if menuCursor==1 then ">" else " ") ++ "Continue " ++ (show . fst . saveState) vars++ "-" ++ (show . (+1) . snd . saveState) vars
  color $ Color3 (1.0 :: GLdouble) 1.0 1.0

  preservingMatrix $ do
    translate $ Vector3 (-250 :: GLdouble) (75) 0
    scale (0.15 :: GLdouble) 0.10 0.15
    renderStringGrad Roman 10 "Dedicated to the makers, the players, the history,"
  preservingMatrix $ do
    translate $ Vector3 (-250 :: GLdouble) (55) 0
    scale (0.15 :: GLdouble) 0.10 0.15
    renderStringGrad Roman  20 "  and the 20th anniversary of GRADIUS series."
  mapM_ (\ (y,(strA,strB),i) -> preservingMatrix $ do
    preservingMatrix $ do
      translate $ Vector3 (-180 :: GLdouble) y 0
      scale (0.18 :: GLdouble) 0.18 0.2
      renderStringGrad Roman (20 + i*5) strA
    preservingMatrix $ do
      translate $ Vector3 (60 :: GLdouble) y 0
      scale (0.18 :: GLdouble) 0.18 0.2
      renderStringGrad Roman (25 + i*5) strB
    ) $ zip3 [0,(-35)..] instructions [1..]

  presentFrame

  if Char ' ' `elem` keystate && clock >= timeLimit then
     if menuCursor == 0 then
       gameStart 1 0 False (recorderMode vars) vars
     else
       gameStart savedLevel savedArea (isCheat vars) (recorderMode vars) vars
   else if isJust $ getNumberKey keystate then
      gameStart (fromJust $ getNumberKey keystate) 0 True (recorderMode vars) vars
    else return $ Scene $ openingProc shieldTextures ses sounds (clock+1) (nextCursor keystate) vars ks
  where
     instructions = [("Move","Arrow Keys"),("Shot","A Key"),("Missile","A Key"),("Power Up","F Key"),("Start","Space Bar")]
     timeLimit = 30 :: Int
     renderStringGrad font delay str = renderString font (take (((clock-delay) * length str) `div` timeLimit) str)
     getNumberKey keystate = foldl mplus Nothing $ map keyToNumber keystate

     keyToNumber :: Key -> Maybe Int
     keyToNumber k = case k of
       Char c -> if c>='0' && c<='9' then Just $ fromEnum c - fromEnum '0' else Nothing
       _      -> Nothing

     gameStart level area ischeat recordermode vrs = do
       stopMusic sounds
       playSound (start ses)
       backgroundMusic (stageMusic level)
      -- it is possible to temporary set (recordermode /= recorderMode vars)
       gs <- newIORef $ initialRecorder recordermode (playbackKeys vrs) (initialMonadius GameVariables{
       totalScore=0, flagGameover=False,  hiScore=saveHiScore vrs,
       nextTag=0, gameClock = savePoints!!area ,baseGameLevel = level,
       stageEntranceFrames = if level == 1 then 120 else 0,
       playTitle = if recordermode /= Playback then Nothing else playBackName vrs})
       when (level == 1) $ do
         c_setEffeksserPlayerPosition (-340) 0
         c_restartEffeksser 12
         playSound (efopen ses)
       return $ Scene $ mainProc shieldTextures ses sounds vrs{isCheat=ischeat,recordSaveState=(level,area)} gs ks

     stageMusic level = case level of
       1 -> bgm1 sounds
       2 -> bgm2 sounds
       3 -> bgm3 sounds
       _ -> bgm1 sounds

     (savedLevel,savedArea) = saveState vars

     demoStart vrs = do
       let i = demoIndex vrs
       let ReplayInfo ((lv,area),dat) = demoData!!i
       gameStart lv area (isCheat vrs) Playback vrs{
         playBackName = Just "Press Space",
         playbackKeys = decode dat,
         demoIndex = demoIndex vrs+1
       }

     nextCursor keys =
       if SpecialKey KeyLeft `elem` keys then 0 else
       if SpecialKey KeyRight `elem` keys then 1 else
       menuCursor

     delayVertices clck vs = (reverse . take clck . reverse) vs

     lambdaLfoot = moreVertices $ [10:+55,(-15):+0] ++ map (\(x:+y)->((-x):+y)) wing
     lambdaRfoot = moreVertices $ [(-15):+70,(-12):+77,(-5):+80,(2:+77),(5:+70)] ++ wing

     shine t = monoshine (drawCompleteTime + t) + monoshine (drawCompleteTime + t+6)

     monoshine t = exp(-0.2*intToGLdouble(t`mod` 240))

     drawCompleteTime = length lambdaRfoot

     moreVertices (a:b:cs) = if magnitude (a-b) > d then moreVertices (a:((a+b)/(2:+0)):b:cs) else a:moreVertices(b:cs)
       where d=6

     moreVertices x = x

     wing = [(30:+0),(200:+0),(216:+16),(208:+24),(224:+24),(240:+40),(232:+48),(248:+48),(272:+72),(168:+72)]

     renderVertices2D :: [Complex GLdouble] -> IO ()
     renderVertices2D xys = mapM_ (\(x:+y) -> vertex $ Vertex3 x y 0) xys

     demoStartTime = if presentationMode then 1350 else 1800
--     demoStartTime = if presentationMode then 480 else 1800
--     demoStartTime = if presentationMode then 4800 else 1800

endingProc :: [GL.TextureObject] -> SEs -> Sounds -> GlobalVariables -> IORef [Key] -> IORef GLdouble -> IO Scene
endingProc shieldTextures ses sounds vars ks ctr= do
  keystate <- readIORef ks
  counter <- readIORef ctr
  modifyIORef ctr (min 2420 . (+2.0))
  clear [ColorBuffer,DepthBuffer]
  matrixMode Graphics.UI.GLUT.$= Modelview 0
  loadIdentity

  color $ Color3 (1.0 :: GLdouble) 1.0 1.0
  zipWithM_ (\str pos -> preservingMatrix $ do
    translate $ Vector3 (-180 :: GLdouble) (-240+counter-pos) 0
    scale (0.3 :: GLdouble) 0.3 0.3
    renderString Roman str)
    stuffRoll [0,60..]

  presentFrame

  if Char ' ' `elem` keystate then do
      return $ Scene $ openingProc shieldTextures ses sounds 0 1 vars ks
   else return $ Scene $ endingProc shieldTextures ses sounds vars ks ctr

  where
    stuffRoll = [
     "",
     "",
     "Game Designer",
     "    nushio",
     "",
     "Frame Programmer",
     "    tanakh",
     "",
     "Graphics Designer",
     "    Just nushio",
     "",
     "Sound Designer",
     "    Match Makers",
     "",
     "Lazy Evaluator",
     "    GHC 6.8",
     "",
     "Inspired"   ,
     "    Ugo-Tool",
     "    gradius2.com",
     "    Gradius series",
     "",
     "Special thanks to",
     "    John Peterson",
     "    Simon Marlow",
     "    Haskell B. Curry",
     "    U.Glasgow",
     "",
     "Presented by",
     "    team combat",
     "",
     "",
     if (fst . saveState) vars <= 2 then "Congratulations!" else "WE LOVE GAMES!!" ,
     "",
     "    press space key"]

mainProc :: [GL.TextureObject] -> SEs -> Sounds -> GlobalVariables -> IORef Recorder -> IORef [Key] -> IO Scene
mainProc shieldTextures ses sounds vars gs ks = do
  keystate <- readIORef ks
  reportColabStatus $ "scene=game keys=" ++ show keystate
  beforegamestate <- readIORef gs
  playSe sounds ses keystate beforegamestate
  modifyIORef gs (update keystate)
  gamestate <- readIORef gs

  clear [ColorBuffer,DepthBuffer]
  matrixMode Graphics.UI.GLUT.$= Modelview 0
  loadIdentity

  render shieldTextures keystate gamestate

  c_procEffeksser

  presentFrame
  let currentLevel = baseGameLevel$getVariables$gameBody gamestate
  let currentArea = maximum $ filter (\i -> (savePoints !! i) < (gameClock $ getVariables $ gameBody gamestate)) [0..(length savePoints-1)]
  let currentSave = if mode gamestate == Playback then saveState vars else (currentLevel,currentArea)
  let currentHi = max (saveHiScore vars) (hiScore$getVariables$gameBody gamestate)
  if (isGameover gamestate) then do
      counter <- newIORef (0.0 :: GLdouble)
      if mode gamestate /= Record then return () else do
        writeReplay vars gamestate $ show (ReplayInfo (recordSaveState vars,(encode2 . preEncodedKeyBuf) gamestate))

      if currentLevel>1 && (not . isCheat) vars && (mode gamestate /= Playback) then do
        backgroundMusic (bgm4 sounds)
        return $ Scene $ endingProc shieldTextures ses sounds vars{saveState=currentSave,saveHiScore = currentHi} ks counter
       else do
         backgroundMusic (bgm0 sounds)
         return $ Scene $ openingProc shieldTextures ses sounds 0 1 vars{saveState=currentSave,saveHiScore = currentHi} ks
    else return $ Scene $ mainProc shieldTextures ses sounds vars{saveState=currentSave,saveHiScore = currentHi} gs ks
  where
    writeReplay vs gamestate str = do
--      home <- getEnv "HOME"
--      home <- getEnv "homepath"
--      createDirectoryIfMissing True (home ++ "\\.monadius-replay\\")
--      createDirectoryIfMissing True ("D:\\.monadius-replay\\")
      createDirectoryIfMissing True ("/home/yamaguchi/Haskell/ALUT-master/.monadius-replay/")
      filename <- searchForNewFile (
          "replay\\" ++ (showsave . recordSaveState) vs ++ "-" ++ (showsave . saveState) vs ++ "." ++
          ((padding '0' 8) . show . totalScore . getVariables . gameBody) gamestate ++ "pts") 0
      writeFile ("/home/yamaguchi/Haskell/ALUT-master/.monadius-replay/" ++ filename) str
--      writeFile ("D:\\.monadius-replay\\" ++ filename) str
    showsave (a,b) = show (a,b+1)
    searchForNewFile prefix i = do
      let fn = prefix ++ (uniqStrs!!i) ++ replayFileExtension
      b <- doesFileExist fn
      if not b then return fn else do
        searchForNewFile prefix $ i + 1
    uniqStrs = ("") : (map (("." ++) . show) ([1..] :: [Int]))

timerProc :: IO () -> IO ()
timerProc m = addTimerCallback 16 $ timerProc m >> m

keyProc :: IORef [Key] -> Key -> KeyState -> t -> t1 -> IO ()
keyProc keystate key ks _ _ =
  case (key,ks) of
    (Char 'q',_) -> exitLoop
    (Char '\ESC',_) -> exitLoop
    (_,Down) -> modifyIORef keystate (nub . (++ [key]))
    (_,Up) -> modifyIORef keystate (filter (/=key))

savePoints :: [Int]
savePoints = [0,1280,3000,6080]
