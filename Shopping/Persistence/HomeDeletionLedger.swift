import Foundation

extension PersonalCartRepository {
    func homeDeletions() throws -> [HomeDeletionStatus] {
        var commands = try values(HomeDeletionCommand.self, kind: "homeDeletion")
        let checkpoints = try values(HomeDeletionCheckpoint.self, kind: "homeDeletionCheckpoint")
        for (id, coverage) in try values(HomeDeletionCoverage.self, kind: "homeDeletionCoverage") {
            try coverage.validate()
            guard id == coverage.id, commands[coverage.command.id] == nil || commands[coverage.command.id] == coverage.command else {
                throw PersonalCartError.corruptRecord
            }
            commands[coverage.command.id] = coverage.command
        }
        for (id, checkpoint) in checkpoints {
            guard id == checkpoint.id else { throw PersonalCartError.corruptRecord }
            if let previous = commands[checkpoint.command.id], previous != checkpoint.command {
                throw PersonalCartError.corruptRecord
            }
            commands[checkpoint.command.id] = checkpoint.command
        }
        return try commands.map { id, command in
            try command.validate()
            guard id == command.id, let scope = command.scope,
                  scope.accountBinding == session.accountBinding,
                  scope.containerIdentifier == session.containerIdentifier,
                  scope.environment == session.environment else { throw PersonalCartError.corruptRecord }
            return HomeDeletionStatus(command: command,
                submitted: checkpoints[HomeDeletionCheckpoint(command: command, stage: .submitted).id] != nil,
                completed: checkpoints[HomeDeletionCheckpoint(command: command, stage: .completed).id] != nil)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// A permanent semantic tombstone; neither rejoin nor imported grants can erase it.
    func isHomeDeleted(householdID: UUID, listID: UUID) throws -> Bool {
        try homeDeletions().contains { $0.command.graph.householdID == householdID && $0.command.graph.listID == listID }
    }

    func retainHomeDeletion(_ command: HomeDeletionCommand) throws {
        try command.validate()
        guard let scope = command.scope, scope.accountBinding == session.accountBinding,
              scope.containerIdentifier == session.containerIdentifier, scope.environment == session.environment else {
            throw PersonalCartError.accountChanged
        }
        if let existing = try homeDeletions().first(where: { $0.command.graph == command.graph }), existing.command != command {
            throw HomeDeletionError.scopeChanged
        }
        try insert(id: command.id, kind: "homeDeletion", command: command, value: command)
    }

    func checkpointHomeDeletion(_ command: HomeDeletionCommand, stage: HomeDeletionCheckpoint.Stage) throws {
        guard try homeDeletions().contains(where: { $0.command == command }) else { throw HomeDeletionError.scopeChanged }
        let checkpoint = HomeDeletionCheckpoint(command: command, stage: stage)
        try insert(id: checkpoint.id, kind: "homeDeletionCheckpoint", command: checkpoint, value: checkpoint)
    }

    func homeDeletionObjectURIs(_ command: HomeDeletionCommand) throws -> Set<String> {
        var result = command.objectURIs
        for coverage in try values(HomeDeletionCoverage.self, kind: "homeDeletionCoverage").values where coverage.command.id == command.id {
            try coverage.validate()
            guard coverage.command == command else { throw PersonalCartError.corruptRecord }
            result.formUnion(coverage.objectURIs)
        }
        return result
    }

    func retainHomeDeletionCoverage(_ command: HomeDeletionCommand, objectURIs: Set<String>) throws {
        guard try homeDeletions().contains(where: { $0.command == command }) else { throw HomeDeletionError.scopeChanged }
        let coverage = HomeDeletionCoverage(command: command, objectURIs: objectURIs)
        try coverage.validate()
        try insert(id: coverage.id, kind: "homeDeletionCoverage", command: coverage, value: coverage)
    }
}

extension PersonalCartService {
    func retainedHomeDeletions() throws -> [HomeDeletionStatus] { try transact(save: false) { try $0.homeDeletions() } }

    func hasCompletedHomeDeletion(storeIdentifier: String, householdID: UUID, listID: UUID) throws -> Bool {
        try transact(save: false) { repository in
            try repository.homeDeletions().contains {
                $0.completed && $0.command.graph.storeIdentifier == storeIdentifier
                    && $0.command.graph.householdID == householdID && $0.command.graph.listID == listID
            }
        }
    }
}
