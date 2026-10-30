/// Non-web storage does not use browser-origin coordination.
class BrowserRuntimeLock {
  Future<void> acquire() async {}
  Future<void> release() async {}
}
