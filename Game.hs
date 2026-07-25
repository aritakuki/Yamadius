module Game (Game(..)) where

import qualified Graphics.Rendering.OpenGL.GL      as GL
import           Graphics.UI.GLUT.Callbacks.Window
import           Util

-- | An abstracted game as a state machine.
class Game g where
  update :: [Key] -> g -> g
  render :: [GL.TextureObject] -> [Key] -> g -> IO ()
  isGameover :: g -> Bool
  playSe :: Sounds -> SEs -> [Key] -> g -> IO ()
