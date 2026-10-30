// Heute-Reiter, Paket 4: Tagesplan als kurze Zeitleiste (vergangene Blöcke
// gedimmt, der laufende hervorgehoben), Knöpfe zum Planen/Löschen, und die
// Wochenziele als kleine Karte.
import SwiftUI
import TabyCore
import UniformTypeIdentifiers

struct PlanSection: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var busy = false
  /// Aufgaben-Auswahl inline statt der Plan-Ansicht; `pickingItems` nil = aus dem Plan.
  @State private var picking = false
  @State private var pickingStep: PlanPickerView.Step = .select
  @State private var pickingItems: [PlanPickItem]?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// In Snapshots ohne Ziehen: der Renderer zeichnet Ziel-Markierungen falsch ein.
  @Environment(\.tabySnapshot) private var snapshot
  /// Ziehen per Maus: gezogener Block und Lücke (0…count), wo er beim Loslassen landet.
  @State private var dragId: String?
  @State private var dragSlot: Int?
  /// Block, dessen Grund inline offen ist (Info-Knopf); Snapshots öffnen ihn sofort.
  @State private var reasonOpen: String?

  init(state: AppState, reasonOpen: String? = nil) {
    self.state = state
    _reasonOpen = State(initialValue: reasonOpen)
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var openTasks: [TabyTask] { state.tasks.filter { !$0.done } }
  /// Prioritätsliste in gemerkter Reihenfolge, nur offene Aufgaben.
  private var priorityItems: [TabyTask] {
    state.taskPriority.compactMap { id in state.tasks.first { $0.id == id && !$0.done } }
  }

  var body: some View {
    if picking {
      PlanPickerView(tasks: openTasks, plan: state.plan, events: state.overview.eventsToday,
                     initialStep: pickingStep, initialItems: pickingItems,
                     notionSourceLinks: state.notionSourceLinks, notionSources: state.notionSources,
                     notionTaskGroups: state.notionTaskGroups, onClose: { picking = false })
    } else {
      VStack(alignment: .leading, spacing: 10) {
        if !priorityItems.isEmpty { PriorityListCard(items: priorityItems) }
        if let plan = state.plan, !plan.blocks.isEmpty {
          planned(plan)
        } else if !openTasks.isEmpty {
          unplanned
        }
      }
    }
  }

  private func openPicker(step: PlanPickerView.Step = .select, items: [PlanPickItem]? = nil) {
    pickingStep = step
    pickingItems = items
    picking = true
  }

  // MARK: Mit Plan

  private func planned(_ plan: DayPlan) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        SectionHeader(symbol: "wand.and.stars", title: "Plan", count: plan.blocks.count, tint: Theme.amber)
        Spacer(minLength: 4)
        Button("Aufgaben wählen") { openPicker() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          .fixedSize()
        Button("Neu planen") { planAgain() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Button("Plan löschen") { clear() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      .padding(.horizontal, 4)
      if let hint = PlanLogic.unplannedHint(plan.unplanned.count) {
        Text(hint).font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.horizontal, 4)
      }
      VStack(spacing: 2) {
        ForEach(Array(plan.blocks.enumerated()), id: \.element.id) { i, b in blockRow(b, at: i, in: plan) }
      }
      .padding(.horizontal, 4)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dragSlot)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dragId)
      // Loslassen außerhalb einer Zeile: Ziehzustand zurücksetzen (Zeilen behandeln ihr Loslassen selbst).
      .modifier(PlanListDragCancel(enabled: !snapshot, dragging: Binding(
        get: { dragId != nil },
        set: { if !$0 { dragId = nil; dragSlot = nil } })))
    }
    .disabled(busy)
    // Verschwindet die Liste mitten im Ziehen (Reiterwechsel), darf kein Ziehzustand hängen bleiben.
    .onDisappear { dragId = nil; dragSlot = nil }
  }

  private func blockRow(_ b: PlannedBlock, at index: Int, in plan: DayPlan) -> some View {
    let st = PlanLogic.status(b, now: now)
    let current = st == .current
    return VStack(alignment: .leading, spacing: 2) {
    HStack(spacing: 10) {
      // Klick auf Zeit und Titel öffnet die Auswahl bei den Uhrzeiten; die Knöpfe rechts bleiben eigen.
      Button { openPicker(step: .times, items: PlanPickerLogic.items(from: plan.blocks)) } label: {
        HStack(spacing: 10) {
          HStack(spacing: 4) {
            Text(PlanLogic.timeRange(b))
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(current ? Theme.text : Theme.secondary)
              .monospacedDigit()
            if b.isPinned {
              Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.secondary)
                .help("Feste Uhrzeit")
            }
          }
          .frame(width: 98, alignment: .leading)
          Circle()
            .fill(current ? Theme.amber : Theme.tertiary)
            .frame(width: 7, height: 7)
            .shadow(color: current ? Theme.amber.opacity(0.9) : .clear, radius: 4)
          Text(b.title)
            .font(.system(size: 13, weight: current ? .semibold : .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
          Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Zeit und Dauer ändern")
      if let reason = b.reason {
        Button { withAnimation(Theme.spring) { reasonOpen = reasonOpen == b.id ? nil : b.id } } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(RoundIconButtonStyle(size: 20, filled: reasonOpen == b.id, tint: Theme.tertiary))
        .help(reason)
        .accessibilityLabel("Grund anzeigen")
      }
      if current { Chip(text: "Jetzt", tint: Theme.amber) }
      Button { move(plan, index, by: -1) } label: { Image(systemName: "chevron.up") }
        .buttonStyle(RoundIconButtonStyle(size: 20))
        .disabled(index == 0)
        .help("Nach oben")
      Button { move(plan, index, by: 1) } label: { Image(systemName: "chevron.down") }
        .buttonStyle(RoundIconButtonStyle(size: 20))
        .disabled(index == plan.blocks.count - 1)
        .help("Nach unten")
      Button { reorder(plan, plan.blocks.filter { $0.id != b.id }) } label: { Image(systemName: "xmark") }
        .buttonStyle(RoundIconButtonStyle(size: 20, tint: Theme.tertiary))
        .help("Aus dem Plan nehmen")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(current ? Theme.amber.opacity(0.12) : Color.clear))
    // Gezogene Zeile wird angehoben und blass; die Lücke zeigt, wo sie landet.
    .scaleEffect(dragId == b.id ? 1.02 : 1)
    .opacity((st == .past ? 0.45 : 1) * (dragId == b.id ? 0.6 : 1))
    .overlay(alignment: .top) { dropMarker(dragSlot == index).offset(y: -3) }
    .overlay(alignment: .bottom) { dropMarker(dragSlot == index + 1).offset(y: 3) }
    .modifier(PlanRowDragging(enabled: !snapshot, id: b.id,
                              onStart: { dragId = b.id },
                              dragActive: { dragId != nil },
                              hover: { dragSlot = slot(over: b.id) },
                              leave: { dragSlot = nil },
                              drop: { payload in dropPayload(payload, onto: b.id) }))
      if reasonOpen == b.id, let reason = b.reason {
        Text(reason)
          .font(.system(size: 11))
          .foregroundStyle(Theme.secondary)
          .padding(.leading, 126)
          .transition(Theme.rowTransition)
      }
    }
  }

  /// Lücke, an der der gezogene Block über der Zeile `id` landen würde (nil = kein gültiges Ziel).
  private func slot(over id: String) -> Int? {
    guard let dragId, let plan = state.plan,
          let from = plan.blocks.firstIndex(where: { $0.id == dragId }),
          let over = plan.blocks.firstIndex(where: { $0.id == id }) else { return nil }
    return PlanReorderLogic.slot(dragging: from, over: over)
  }

  /// Loslassen auf Zeile `targetId`. Die Nutzlast muss eine Zeile dieses Plans sein; die
  /// Indizes werden erst jetzt aus den IDs aufgelöst, nicht aus einem früheren Renderstand.
  private func dropPayload(_ payload: String, onto targetId: String) {
    dragId = nil
    dragSlot = nil
    guard payload.hasPrefix(PlanDragPayload.prefix), let plan = state.plan else { return }
    let fromId = String(payload.dropFirst(PlanDragPayload.prefix.count))
    guard let from = plan.blocks.firstIndex(where: { $0.id == fromId }),
          let over = plan.blocks.firstIndex(where: { $0.id == targetId }) else { return }
    dropMove(plan, from: from, slot: PlanReorderLogic.slot(dragging: from, over: over))
  }

  private func dropMarker(_ visible: Bool) -> some View {
    Capsule().fill(Theme.amber).frame(height: 3).padding(.horizontal, 8)
      .opacity(visible ? 1 : 0)
      .allowsHitTesting(false)
  }

  /// Ziehen: Block vor die Lücke `slot` setzen, sonst nichts tun.
  private func dropMove(_ plan: DayPlan, from: Int, slot: Int) {
    let blocks = PlanReorderLogic.moved(plan.blocks, from: from, before: slot)
    guard blocks.map(\.id) != plan.blocks.map(\.id) else { return }
    reorder(plan, blocks)
  }

  // MARK: Ohne Plan

  private var unplanned: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader(symbol: "wand.and.stars", title: "Plan", tint: Theme.amber)
        .padding(.horizontal, 4)
      HStack(spacing: 10) {
        Button { planAgain() } label: {
          Label("Aufgaben einplanen", systemImage: "wand.and.stars")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button { openPicker() } label: {
          Label("Aufgaben wählen", systemImage: "calendar.badge.plus")
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        if let hint = PlanLogic.unplannedHint(state.plan?.unplanned.count ?? 0) {
          Text(hint).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
    }
    .disabled(busy)
  }

  // MARK: Aktionen

  private func planAgain() {
    busy = true
    Task {
      let result = await model.services.planDay()
      await model.refresh()
      busy = false
      if result.isOk {
        model.react(.celebrate)
      } else if let e = result.errorMessage {
        model.react(.failed(e))
      }
    }
  }

  private func clear() {
    busy = true
    Task {
      await model.services.clearPlan()
      await model.refresh()
      busy = false
    }
  }

  private func move(_ plan: DayPlan, _ index: Int, by delta: Int) {
    var blocks = plan.blocks
    guard blocks.indices.contains(index + delta) else { return }
    blocks.swapAt(index, index + delta)
    reorder(plan, blocks)
  }

  /// Schickt die neue Reihenfolge an den Kern; nicht eingeplante Aufgaben bleiben hinten dran.
  private func reorder(_ plan: DayPlan, _ blocks: [PlannedBlock]) {
    busy = true
    Task {
      _ = await model.services.reorderPlan(taskIds: blocks.map(\.taskId) + plan.unplanned)
      await model.refresh()
      busy = false
    }
  }
}

/// Nutzlast beim Ziehen einer Plan-Zeile: eigener Typ, damit fremder Text nie als Zeile gilt.
enum PlanDragPayload {
  static let type = UTType(importedAs: "app.taby.plan-row")
  static let prefix = "taby-plan-row:"
}

/// Setzt den Ziehzustand zurück, wenn der Zeiger die Liste ohne Loslassen verlässt (aus in Snapshots).
struct PlanListDragCancel: ViewModifier {
  let enabled: Bool
  let dragging: Binding<Bool>

  func body(content: Content) -> some View {
    if enabled {
      content.onDrop(of: [PlanDragPayload.type], isTargeted: dragging) { _, _ in false }
    } else {
      content
    }
  }
}

/// Ziehen und Loslassen einer Plan-Zeile (aus in Snapshots).
struct PlanRowDragging: ViewModifier {
  let enabled: Bool
  let id: String
  let onStart: () -> Void
  let dragActive: () -> Bool
  let hover: () -> Void
  let leave: () -> Void
  let drop: (String) -> Void

  func body(content: Content) -> some View {
    if enabled {
      content
        .onDrag {
          onStart()
          let provider = NSItemProvider()
          provider.registerDataRepresentation(forTypeIdentifier: PlanDragPayload.type.identifier,
                                              visibility: .all) { completion in
            completion(Data((PlanDragPayload.prefix + id).utf8), nil)
            return nil
          }
          return provider
        }
        .onDrop(of: [PlanDragPayload.type], delegate: PlanRowDropDelegate(
          accepts: dragActive, hover: hover, leave: leave, drop: drop))
    } else {
      content
    }
  }
}

/// Zeile des Tagesplans als Ziel beim Ziehen: meldet die Lücke beim Überfahren, reicht die
/// Nutzlast beim Loslassen weiter. Angenommen wird nur die eigene Nutzlast während eines Ziehens.
struct PlanRowDropDelegate: DropDelegate {
  let accepts: () -> Bool
  let hover: () -> Void
  let leave: () -> Void
  let drop: (String) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    accepts() && info.hasItemsConforming(to: [PlanDragPayload.type])
  }

  func dropEntered(info: DropInfo) { hover() }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    hover()
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) { leave() }

  func performDrop(info: DropInfo) -> Bool {
    guard accepts(), let provider = info.itemProviders(for: [PlanDragPayload.type]).first else { return false }
    leave()
    _ = provider.loadDataRepresentation(forTypeIdentifier: PlanDragPayload.type.identifier) { data, _ in
      guard let data, let text = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async { drop(text) }
    }
    return true
  }
}

/// Prioritätsliste: Aufgaben, die der Tagesplan zuerst einplant. Pfeile ordnen um, ✕ nimmt eine heraus.
struct PriorityListCard: View {
  let items: [TabyTask]
  @EnvironmentObject private var model: AppModel
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader(symbol: "star.fill", title: "Priorität", count: items.count, tint: Theme.amber)
        .padding(.horizontal, 4)
      ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
        HStack(spacing: 10) {
          Text(t.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
          Spacer(minLength: 4)
          Button { save(swapped(i, i - 1)) } label: { Image(systemName: "chevron.up") }
            .buttonStyle(RoundIconButtonStyle(size: 20))
            .disabled(i == 0)
            .help("Nach oben")
          Button { save(swapped(i, i + 1)) } label: { Image(systemName: "chevron.down") }
            .buttonStyle(RoundIconButtonStyle(size: 20))
            .disabled(i == items.count - 1)
            .help("Nach unten")
          Button { save(items.map(\.id).filter { $0 != t.id }) } label: { Image(systemName: "xmark") }
            .buttonStyle(RoundIconButtonStyle(size: 20, tint: Theme.tertiary))
            .help("Von der Prioritätsliste nehmen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
      }
    }
    .tabyCard(tint: Theme.amber, padding: 10)
    .disabled(busy)
  }

  private func swapped(_ i: Int, _ j: Int) -> [String] {
    var ids = items.map(\.id)
    guard ids.indices.contains(j) else { return ids }
    ids.swapAt(i, j)
    return ids
  }

  private func save(_ ids: [String]) {
    busy = true
    Task {
      _ = await model.services.setTaskPriority(taskIds: ids)
      await model.refresh()
      busy = false
    }
  }
}

/// Wochenziele (bis zu drei) mit Häkchen und Knopf zur Wochenplanung.
struct WeeklyGoalsCard: View {
  let goals: [WeeklyGoal]
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        SectionHeader(symbol: "target", title: "Wochenziele", tint: Theme.green)
        Spacer(minLength: 4)
        Button {
          Task { await model.services.openWeeklyReview() }
        } label: {
          Label("Wochenplanung", systemImage: "calendar.badge.clock")
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      ForEach(Array(goals.prefix(3))) { g in
        HStack(spacing: 10) {
          CheckCircle(checked: g.done, size: 18) { toggle(g) }
          Text(g.text)
            .font(.system(size: 13))
            .foregroundStyle(g.done ? Theme.tertiary : Theme.text)
            .strikethrough(g.done, color: Theme.tertiary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
      }
    }
    .tabyCard(tint: Theme.green, padding: 10)
  }

  private func toggle(_ g: WeeklyGoal) {
    Task {
      _ = await model.services.setWeeklyGoalDone(g.id, !g.done)
      await model.refresh()
    }
  }
}
