# duluth and bemidji only: they share an Intel Arrow Lake-P iGPU (8086:7d51).
# fargo has an older Alder Lake-P (8086:46a6) that i915 supports as-is, do not
# apply this there. The fleet's GPU hardware is not uniform; check
# `lspci -nn | grep VGA` before extending this to another host.
#
# Both i915 and xe can claim Arrow Lake and whichever probes first wins, so xe
# is blocked and i915 gets an explicit force_probe for an ID this new. The
# kernel side alone is not enough - the Intel GPU device plugin and Plex's
# VAAPI stack are the other half.
{
  boot.blacklistedKernelModules = [ "xe" ];
  boot.kernelParams = [ "i915.force_probe=7d51" ];
}
