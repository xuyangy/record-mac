import Foundation

struct EditorHistory<State: Equatable> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var transactionStart: State?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isInTransaction: Bool { transactionStart != nil }

    mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        transactionStart = nil
    }

    mutating func recordChange(
        from before: State,
        to after: State,
        shouldRecord: (State, State) -> Bool = { $0 != $1 }
    ) {
        guard transactionStart == nil, shouldRecord(before, after) else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }

    mutating func beginTransaction(current state: State) {
        guard transactionStart == nil else { return }
        transactionStart = state
    }

    @discardableResult
    mutating func commitTransaction(
        current state: State,
        shouldRecord: (State, State) -> Bool = { $0 != $1 }
    ) -> Bool {
        guard let transactionStart else { return false }
        self.transactionStart = nil
        guard shouldRecord(transactionStart, state) else { return false }
        undoStack.append(transactionStart)
        redoStack.removeAll()
        return true
    }

    mutating func cancelTransaction() {
        transactionStart = nil
    }

    mutating func undo(current state: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        transactionStart = nil
        redoStack.append(state)
        return previous
    }

    mutating func redo(current state: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        transactionStart = nil
        undoStack.append(state)
        return next
    }
}
