module Game (Game(..)) where

import           Graphics.UI.GLUT.Callbacks.Window
import           Util

-- | An abstracted game as a state machine.
class Game g where
  update :: [Key] -> g -> g
  render :: [Key] -> g -> IO ()
  isGameover :: g -> Bool
  playSe :: Sounds -> SEs -> [Key] -> g -> IO ()
