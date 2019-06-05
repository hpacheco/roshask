all:
	cabal install --force-reinstalls
	cabal install msgs/Geometry_msgs/ msgs/Std_msgs/ msgs/Kobuki_msgs/ msgs/Nav_msgs/ msgs/Std_srvs/ msgs/Actionlib_msgs/ --force-reinstalls
	cabal install rosy/
