{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.Led where
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

data Led = Led
    { _value :: Word.Word8
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

value_BLACK,value_GREEN,value_ORANGE,value_RED :: Word.Word8
value_BLACK = 0
value_GREEN = 1
value_ORANGE = 2
value_RED = 3

$(makeLenses ''Led)

instance RosBinary Led where
  put obj' = put (_value obj') 
  get = Led <$> get 

instance Storable Led where
  sizeOf _ = sizeOf (P.undefined::Word.Word8)
  alignment _ = 8
  peek = SM.runStorable (Led <$> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_value obj')

instance MsgInfo Led where
  sourceMD5 _ = "4391183b0cf05f8f25d04220401b9f43"
  msgTypeName _ = "kobuki_msgs/Led"

instance D.Default Led

