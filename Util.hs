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
  ) where

import           Control.Concurrent
import           Control.Monad             (unless, when)
import           Control.Monad.Fix         (fix)
import           Data.Array                (Array, Ix, (!), (//))
import           Data.Complex
import           Data.List                 (intersperse)
import           Data.Maybe
import           Graphics.Rendering.OpenGL
import           Sound.ALUT
import           System.Exit               (exitFailure)
import           System.IO                 (hPutStrLn, stderr)

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


data Sounds = Sounds { bgm0 :: Source
                     , bgm1 :: Source
                     , bgm2 :: Source
                     , bgm3 :: Source
                     , bgm4 :: Source }

data SEs = SEs { start           :: Source
                  , shot         :: Source
                  , laserSe      :: Source
                  , crash        :: Source
                  , hatchCrash   :: Source
                  , damageHatch  :: Source
                  , damageShield :: Source
                  , getCapsule   :: Source
                  , speedUp      :: Source
                  , missile      :: Source
                  , double       :: Source
                  , laser        :: Source
                  , option       :: Source
                  , shieldVoice  :: Source
                  , destroy      :: Source
                  , launcher3    :: Source
                  , launchers    :: Source
                  , eftsuki      :: Source
                  , efatchi      :: Source
                  , efwarero     :: Source
                  , eficchimae   :: Source
                  , efkaze       :: Source
                  , efopen       :: Source }

loadSounds :: IO Sounds
loadSounds = do
    bgm0Source <- loadSound "BGM/bgm0.wav"
    bgm1Source <- loadSound "BGM/bgm1.wav"
    bgm2Source <- loadSound "BGM/bgm2.wav"
    bgm3Source <- loadSound "BGM/bgm3.wav"
    bgm4Source <- loadSound "BGM/bgm4.wav"
    sourceGain bgm0Source Sound.ALUT.$= 1.0
    sourceGain bgm1Source Sound.ALUT.$= 1.0
    sourceGain bgm2Source Sound.ALUT.$= 1.0
    sourceGain bgm3Source Sound.ALUT.$= 1.0
    sourceGain bgm4Source Sound.ALUT.$= 1.0
    return $ Sounds bgm0Source bgm1Source bgm2Source bgm3Source bgm4Source

loadSound :: FilePath -> IO Source
loadSound path = do
    buf <- createBuffer (File path)
    source <- genObjectName
    buffer source Sound.ALUT.$= Just buf
    return source

backgroundMusic :: Source -> IO ()
backgroundMusic source = do
        loopingMode source Sound.ALUT.$= Looping
        play [source]

stopMusic :: Sounds -> IO ()
stopMusic (Sounds bgm0Source bgm1Source bgm2Source bgm3Source bgm4Source) = do
        stop [bgm0Source]
        stop [bgm1Source]
        stop [bgm2Source]
        stop [bgm3Source]
        stop [bgm4Source]

playContinuousSound :: Source -> IO ()
playContinuousSound source = do
        state <- Sound.ALUT.get (sourceState source)
        unless (state == Playing) $ play [source]

playSound :: Source -> IO ()
playSound source = do
    play [source]
    -- Normally nothing should go wrong above, but one never knows...
    errs <- Sound.ALUT.get alErrors
    unless (null errs) $ do
        hPutStrLn stderr (concat (intersperse "," [ d | ALError _ d <- errs ]))
    return ()

loadSEs :: IO SEs
loadSEs = do
    startSource <- loadSound "SE/start.wav"
    shotSource <- loadSound "SE/shot.wav"
    sourceGain shotSource Sound.ALUT.$= 0.1
    laserSource <- loadSound "SE/laser.wav"
    sourceGain laserSource Sound.ALUT.$= 0.3
    crashSource <- loadSound "SE/crash.wav"
    sourceGain crashSource Sound.ALUT.$= 0.5
    hatchCrashSource <- loadSound "SE/hatchCrash.wav"
    sourceGain hatchCrashSource Sound.ALUT.$= 1.0
    damageHatchSource <- loadSound "SE/damageHatch.wav"
    sourceGain damageHatchSource Sound.ALUT.$= 1.0
    damageShieldSource <- loadSound "SE/damageShield.wav"
    sourceGain damageShieldSource Sound.ALUT.$= 1.0
    getCapsuleSource <- loadSound "SE/getCapsule.wav"
--    sourceGain getCapsuleSource Sound.ALUT.$= 0.1
    speedUpSource <- loadSound "SE/speedupVoice.wav"
    sourceGain speedUpSource Sound.ALUT.$= 1.0
    missileSource <- loadSound "SE/missileVoice.wav"
    sourceGain missileSource Sound.ALUT.$= 1.0
    doubleSource <- loadSound "SE/doubleVoice.wav"
    sourceGain doubleSource Sound.ALUT.$= 1.0
    laserVoiceSource <- loadSound "SE/laserVoice.wav"
    sourceGain laserSource Sound.ALUT.$= 1.0
    optionSource <- loadSound "SE/optionVoice.wav"
    sourceGain optionSource Sound.ALUT.$= 1.0
    shieldSource <- loadSound "SE/shieldVoice.wav"
    sourceGain shieldSource Sound.ALUT.$= 1.0
    destroySource <- loadSound "SE/destroy.wav"
    sourceGain destroySource Sound.ALUT.$= 1.0
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
