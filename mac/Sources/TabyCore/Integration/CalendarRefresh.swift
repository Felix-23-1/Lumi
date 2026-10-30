import Foundation

extension CoreServices {
  public func refreshCalendars() async {
    calendarAccess.refreshRemoteCaches()
    changed()
  }
}
