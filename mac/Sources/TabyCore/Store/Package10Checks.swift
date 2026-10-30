// Prüfungen für Paket 10 im Speicher: Prioritätsliste (Round Trip, vollständiges
// Ersetzen, leere Liste).
import Foundation

enum Package10StoreChecks {
  static let suite = CheckSuite("Store Paket 10", [
    CheckCase("Prioritätsliste: set/list Round Trip in Reihenfolge") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      try store.taskPriority.set(["b", "a", "c"])
      try expectEqual(try store.taskPriority.list(), ["b", "a", "c"])
    },
    CheckCase("Prioritätsliste: erneutes set ersetzt die ganze Liste") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      try store.taskPriority.set(["a", "b"])
      try store.taskPriority.set(["c"])
      try expectEqual(try store.taskPriority.list(), ["c"])
    },
    CheckCase("Prioritätsliste: leere Liste leert alles") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      try expectEqual(try store.taskPriority.list(), [])
      try store.taskPriority.set(["a"])
      try store.taskPriority.set([])
      try expectEqual(try store.taskPriority.list(), [])
    },
  ])
}
