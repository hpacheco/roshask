{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.RobotStateEvent where
import qualified Prelude as P
import Prelude ((.), (+), (*))
import qualified Data.Typeable as T
import Control.Applicative
import Ros.Internal.RosBinary
import Ros.Internal.Msg.MsgInfo
import qualified GHC.Generics as G
import qualified Data.Default.Generics as D
import qualified Data.Word as Word
import Foreign.Storable (Storable(..))
import qualified Ros.Internal.Util.StorableMonad as SM
import Lens.Family.TH (makeLenses)
import Lens.Family (view, set)

data RobotStateEvent = RobotStateEvent
    { _state :: Word.Word8
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

state_OFFLINE,state_ONLINE :: Word.Word8
state_OFFLINE = 0
state_ONLINE = 1

$(makeLenses ''RobotStateEvent)

instance RosBinary RobotStateEvent where
  put obj' = put (_state obj') 
  get = RobotStateEvent <$> get 

instance Storable RobotStateEvent where
  sizeOf _ = sizeOf (P.undefined::Word.Word8)
  alignment _ = 8
  peek = SM.runStorable (Led <$> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_state obj')

instance MsgInfo RobotStateEvent where
  sourceMD5 _ = "c6eccd4cb1f95df95635b56d6226ea32"
  msgTypeName _ = "kobuki_msgs/RobotStateEvent"

instance D.Default RobotStateEvent

