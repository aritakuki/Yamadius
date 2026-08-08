-- | Various numeric utility functions, particularly dealing with Complex
-- numbers and shapes.
module Util (
  ComplexShape(..),
  Shape(..),
  angleAccuracy,
  filterJust,
  infinite,
  innerProduct,
  intToGLdouble,
  isDebugMode,
  modifyArray,
  padding,
  putDebugStrLn,
  regulate,
  square,
  unitVector,
  Sounds(..),
  SEs(..),
  loadSounds,
  loadSEs,
  stopMusic,
  backgroundMusic,
  playSound,
  stopSound,
  ) where

import           Control.Concurrent
import           Control.Monad             (forM_, forever, unless, when)
import           Control.Monad.Fix         (fix)
import           Data.Array                (Array, Ix, (!), (//))
import           Data.Complex
import           Data.List                 (intersperse)
import           Data.Maybe
import           Data.IORef                (IORef, newIORef, readIORef, writeIORef)
import           Data.Time.Clock.POSIX      (getPOSIXTime)
import           Graphics.Rendering.OpenGL
import           Sound.ALUT
import           Foreign.C.Types           (CFloat)
import           System.Environment        (lookupEnv)
import           System.Exit               (exitFailure)
import           System.IO                 (IOMode (AppendMode), hFlush, hPutStr,
                                            hPutStrLn, stderr, withFile)
import           System.IO.Unsafe          (unsafePerformIO)

-- | Switch this to True to get debug outputs. Be careful: you get a crash under
-- Microsoft Windows, because the console is not available.
isDebugMode :: Bool
isDebugMode = False

putDebugStrLn :: String -> IO ()
putDebugStrLn str = if isDebugMode then putStrLn str else return ()

filterJust :: [Maybe a] -> [a]
filterJust = map fromJust.filter isJust

-- | Modify array 'a' at index 'i' by function 'f'
modifyArray :: Ix i => i -> (e -> e) -> Array i e -> Array i e
modifyArray i f a = a // [(i,f $ a!i)]

class ComplexShape s where
  -- | Collision check
  (>?<) :: s -> s -> Bool
  -- | Translation by a vector
  (+>) :: (Complex GLdouble) -> s -> s

instance ComplexShape Shape where
  a >?< b = case (a,b) of
    (Circular{},Circular{}) -> magnitude (center a - center b) < radius a + radius b
    (Circular{},Rectangular{}) -> b >?< a
    (Rectangular{},Circular{}) -> a >?< Rectangular{bottomLeft = center b - vr,topRight = center b + vr} where
      vr = radius b :+ radius b
    (Rectangular{bottomLeft=aL:+aB,topRight=aR:+aT},Rectangular{bottomLeft=bL:+bB,topRight=bR:+bT}) ->
      and [aL < bR, aB < bT, aR > bL, aT > bB]
    (Shapes{children = ss}, c) -> or $ map (>?< c)  ss
    (d, Shapes{children = ss}) -> or $ map (d >?<)  ss
  v +> a = case a of
    Circular{}    -> a{center = center a + v}
    Rectangular{} -> a{bottomLeft = bottomLeft a + v, topRight = topRight a + v}
    Shapes{}      -> a{children = map (v +>) $ children a}

data Shape = Circular {center :: Complex GLdouble, radius :: GLdouble} |
             Rectangular {bottomLeft :: Complex GLdouble, topRight :: Complex GLdouble} |
             Shapes {children :: [Shape]}

-- | Put a Rectangle coordinates into normal order so that collision will go properly.
regulate :: Shape -> Shape
regulate Rectangular{bottomLeft=(x1:+y1),topRight=(x2:+y2) }= Rectangular (min x1 x2:+min y1 y2) (max x1 x2:+max y1 y2)
regulate ss@Shapes{} = ss{children = map regulate $ children ss}
regulate x = x

intToGLdouble :: Int -> GLdouble
intToGLdouble = fromIntegral

unitVector :: Complex GLdouble -> Complex GLdouble
unitVector z
    | magnitude z <= 0.00000001 = 1:+0
    | otherwise                 = z / abs z

angleAccuracy :: Int -> Complex GLdouble -> Complex GLdouble
angleAccuracy division z = mkPolar r theta
    where
      (r,t)=polar z
      theta = (intToGLdouble $ round (t / (2*pi) * d))/d*2*pi
      d = intToGLdouble division

innerProduct :: Complex GLdouble -> Complex GLdouble -> GLdouble
innerProduct a b = realPart $ a * (conjugate b)

padding :: Char -> Int -> String -> String
padding pad minLen str = replicate (minLen - length str) pad ++ str

infinite :: Int
infinite = 9999999

square :: (Num a) => a -> a
square a = a * a


-- Keep the OpenAL source together with the repository-relative WAV path.
-- Native builds continue to use the source directly.  Colab additionally
-- writes the path to a small event stream so the browser can reproduce the
-- same BGM/SE decisions made by the game engine.
data SoundAsset = SoundAsset { soundSource :: Source
                             , soundPath   :: FilePath
                             , soundGain   :: IORef CFloat }

data Sounds = Sounds { bgm0 :: SoundAsset
                     , bgm1 :: SoundAsset
                     , bgm2 :: SoundAsset
                     , bgm3 :: SoundAsset
                     , bgm4 :: SoundAsset }

data SEs = SEs { start           :: SoundAsset
                  , shot         :: SoundAsset
                  , laserSe      :: SoundAsset
                  , crash        :: SoundAsset
                  , hatchCrash   :: SoundAsset
                  , damageHatch  :: SoundAsset
                  , damageShield :: SoundAsset
                  , getCapsule   :: SoundAsset
                  , speedUp      :: SoundAsset
                  , missile      :: SoundAsset
                  , double       :: SoundAsset
                  , laser        :: SoundAsset
                  , option       :: SoundAsset
                  , shieldVoice  :: SoundAsset
                  , destroy      :: SoundAsset
                  , launcher3    :: SoundAsset
                  , launchers    :: SoundAsset
                  , eftsuki      :: SoundAsset
                  , efatchi      :: SoundAsset
                  , efwarero     :: SoundAsset
                  , eficchimae   :: SoundAsset
                  , efkaze       :: SoundAsset
                  , efopen       :: SoundAsset }

loadSounds :: IO Sounds
loadSounds = do
    bgm0Source <- loadSound "BGM/bgm0.wav"
    bgm1Source <- loadSound "BGM/bgm1.wav"
    bgm2Source <- loadSound "BGM/bgm2.wav"
    bgm3Source <- loadSound "BGM/bgm3.wav"
    bgm4Source <- loadSound "BGM/bgm4.wav"
    setSoundGain bgm0Source 1.0
    setSoundGain bgm1Source 1.0
    setSoundGain bgm2Source 1.0
    setSoundGain bgm3Source 1.0
    setSoundGain bgm4Source 1.0
    return $ Sounds bgm0Source bgm1Source bgm2Source bgm3Source bgm4Source

loadSound :: FilePath -> IO SoundAsset
loadSound path = do
    buf <- createBuffer (File path)
    source <- genObjectName
    gain <- newIORef 1.0
    buffer source Sound.ALUT.$= Just buf
    return $ SoundAsset source path gain

setSoundGain :: SoundAsset -> CFloat -> IO ()
setSoundGain asset gain = do
    sourceGain (soundSource asset) Sound.ALUT.$= gain
    writeIORef (soundGain asset) gain

{-# NOINLINE audioEventWriter #-}
audioEventWriter :: MVar (Maybe (FilePath, Chan String))
audioEventWriter = unsafePerformIO $ newMVar Nothing

audioEventChannel :: FilePath -> IO (Chan String)
audioEventChannel filename = modifyMVar audioEventWriter $ \current ->
    case current of
      Just (activeFilename, channel) | activeFilename == filename ->
        return (current, channel)
      _ -> do
        channel <- newChan
        _ <- forkIO $ withFile filename AppendMode $ \handle -> forever $ do
          event <- readChan channel
          hPutStr handle event
          hFlush handle
        return (Just (filename, channel), channel)

emitAudioEvent :: String -> Maybe SoundAsset -> IO ()
emitAudioEvent action asset = do
    eventFile <- lookupEnv "MONADIUS_AUDIO_EVENT_FILE"
    forM_ eventFile $ \filename -> do
        channel <- audioEventChannel filename
        (path, gain) <- case asset of
          Nothing -> return ("", 1.0)
          Just sound -> do
            currentGain <- readIORef $ soundGain sound
            return (soundPath sound, currentGain)
        -- Browser effects are real-time events, not a replay log.  A wall-clock
        -- timestamp lets the Colab bridge discard an effect that sat behind a
        -- congested media transfer instead of playing it seconds too late.
        emittedAt <- floor . (* 1000) <$> getPOSIXTime :: IO Integer
        writeChan channel $ action ++ "\t" ++ path ++ "\t" ++ show gain ++
          "\t" ++ show emittedAt ++ "\n"

backgroundMusic :: SoundAsset -> IO ()
backgroundMusic asset = do
        loopingMode (soundSource asset) Sound.ALUT.$= Looping
        play [soundSource asset]
        emitAudioEvent "bgm" (Just asset)

stopMusic :: Sounds -> IO ()
stopMusic (Sounds bgm0Source bgm1Source bgm2Source bgm3Source bgm4Source) = do
        stop $ map soundSource [bgm0Source, bgm1Source, bgm2Source, bgm3Source, bgm4Source]
        emitAudioEvent "stop-bgm" Nothing

playContinuousSound :: SoundAsset -> IO ()
playContinuousSound asset = do
        state <- Sound.ALUT.get (sourceState $ soundSource asset)
        unless (state == Playing) $ do
            play [soundSource asset]
            emitAudioEvent "play" (Just asset)

playSound :: SoundAsset -> IO ()
playSound asset = do
    previousState <- Sound.ALUT.get (sourceState $ soundSource asset)
    play [soundSource asset]
    -- OpenAL ignores play on a Source that is already Playing.  Mirror that
    -- behaviour in the browser event stream; several game objects call this
    -- once per frame while the same short effect is still active.
    unless (previousState == Playing) $ emitAudioEvent "play" (Just asset)
    -- Normally nothing should go wrong above, but one never knows...
    errs <- Sound.ALUT.get alErrors
    unless (null errs) $ do
        hPutStrLn stderr (concat (intersperse "," [ d | ALError _ d <- errs ]))
    return ()

stopSound :: SoundAsset -> IO ()
stopSound asset = do
    stop [soundSource asset]
    emitAudioEvent "stop" (Just asset)

loadSEs :: IO SEs
loadSEs = do
    startSource <- loadSound "SE/start.wav"
    shotSource <- loadSound "SE/shot.wav"
    setSoundGain shotSource 0.1
    laserSource <- loadSound "SE/laser.wav"
    setSoundGain laserSource 0.3
    crashSource <- loadSound "SE/crash.wav"
    setSoundGain crashSource 0.5
    hatchCrashSource <- loadSound "SE/hatchCrash.wav"
    setSoundGain hatchCrashSource 1.0
    damageHatchSource <- loadSound "SE/damageHatch.wav"
    setSoundGain damageHatchSource 1.0
    damageShieldSource <- loadSound "SE/damageShield.wav"
    setSoundGain damageShieldSource 1.0
    getCapsuleSource <- loadSound "SE/getCapsule.wav"
--    sourceGain getCapsuleSource Sound.ALUT.$= 0.1
    speedUpSource <- loadSound "SE/speedupVoice.wav"
    setSoundGain speedUpSource 1.0
    missileSource <- loadSound "SE/missileVoice.wav"
    setSoundGain missileSource 1.0
    doubleSource <- loadSound "SE/doubleVoice.wav"
    setSoundGain doubleSource 1.0
    laserVoiceSource <- loadSound "SE/laserVoice.wav"
    setSoundGain laserVoiceSource 1.0
    optionSource <- loadSound "SE/optionVoice.wav"
    setSoundGain optionSource 1.0
    shieldSource <- loadSound "SE/shieldVoice.wav"
    setSoundGain shieldSource 1.0
    destroySource <- loadSound "SE/destroy.wav"
    setSoundGain destroySource 1.0
    launcher3Source <- loadSound "SE/launcher3.wav"
    launchersSource <- loadSound "SE/launchers.wav"
    eftsukiSource <- loadSound "SE/EfTsuki.wav"
    efatchiSource <- loadSound "SE/EfAtchi.wav"
    efwareroSource <- loadSound "SE/EfWarero.wav"
    eficchimaeSource <- loadSound "SE/EfIcchimae.wav"
    efkazeSource <- loadSound "SE/EfKaze.wav"
    efopenSource <- loadSound "SE/EfOpen.wav"
    return $ SEs
      startSource
      shotSource
      laserSource
      crashSource
      hatchCrashSource
      damageHatchSource
      damageShieldSource
      getCapsuleSource
      speedUpSource
      missileSource
      doubleSource
      laserVoiceSource
      optionSource
      shieldSource
      destroySource
      launcher3Source
      launchersSource
      eftsukiSource
      efatchiSource
      efwareroSource
      eficchimaeSource
      efkazeSource
      efopenSource
