// Paket 10 gegen den echten Kern (CoreServices mit SQLite im Speicher, lokalem
// Kalender, steuerbarer Uhr): Plan umsortieren/entfernen, Prioritätsliste wirkt
// auf "Neu planen". Ohne Modell.
import Foundation

enum PackageTenIntegrationChecks {
  @MainActor static var suite: CheckSuite {
    CheckSuite("Integration Paket 10", [
      CheckCase("Plan bearbeiten: reorderPlan ändert die Reihenfolge und lässt die entfernte Aufgabe weg") {
        let rig = try IntegrationRig()  // Montag 08:00
        let svc = rig.svc
        _ = await svc.addTask(title: "Alpha", notes: nil, due: nil)
        _ = await svc.addTask(title: "Beta", notes: nil, due: nil)
        _ = await svc.addTask(title: "Gamma", notes: nil, due: nil)
        let tasks = await svc.state().tasks
        let alpha = tasks.first { $0.title == "Alpha" }?.id ?? ""
        let beta = tasks.first { $0.title == "Beta" }?.id ?? ""
        let gamma = tasks.first { $0.title == "Gamma" }?.id ?? ""
        guard case .ok(let planned) = await svc.planDay() else { throw CheckFailure(message: "kein Plan", location: "") }
        try expectEqual(Set(planned.blocks.map(\.taskId)), Set([alpha, beta, gamma]))

        guard case .ok(let reordered) = await svc.reorderPlan(taskIds: [gamma, alpha]) else {
          throw CheckFailure(message: "reorderPlan fehlgeschlagen", location: "")
        }
        try expectEqual(reordered.blocks.map(\.taskId), [gamma, alpha])
        let state = await svc.state()
        try expectEqual(state.plan?.blocks.map(\.taskId) ?? [], [gamma, alpha])
      },

      CheckCase("Priorität: setTaskPriority filtert unbekannte und doppelte IDs, planDay setzt sie nach vorn") {
        let rig = try IntegrationRig()  // Montag 08:00
        let svc = rig.svc
        _ = await svc.addTask(title: "Alpha", notes: nil, due: nil)
        _ = await svc.addTask(title: "Beta", notes: nil, due: nil)
        _ = await svc.addTask(title: "Gamma", notes: nil, due: nil)
        let tasks = await svc.state().tasks
        let alpha = tasks.first { $0.title == "Alpha" }?.id ?? ""
        let beta = tasks.first { $0.title == "Beta" }?.id ?? ""
        let gamma = tasks.first { $0.title == "Gamma" }?.id ?? ""
        _ = await svc.setTaskPriority(taskIds: [gamma, "unbekannt", alpha, gamma])
        let priority = await svc.state().taskPriority
        try expectEqual(priority, [gamma, alpha])
        guard case .ok(let plan) = await svc.planDay() else { throw CheckFailure(message: "kein Plan", location: "") }
        try expectEqual(plan.blocks.map(\.taskId), [gamma, alpha, beta])
      },
    ])
  }
}
