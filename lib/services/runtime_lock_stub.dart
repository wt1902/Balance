/// Platforms without dart:io or browser APIs need no coordination.
class PlatformRuntimeLock {
  Future<void> acquire() async {}
  Future<void> release() async {}
}
