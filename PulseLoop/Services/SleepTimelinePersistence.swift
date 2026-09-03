import Foundation
import SwiftData

extension SleepService {
    /// Attach a per-minute stage array (one contiguous run starting at `start`) to the waking day it
    /// belongs to, deduping blocks by start minute across the day's sessions, then re-split the day into
    /// sessions. The ring's sleep frames and Apple Health imports both land here.
    static func persistTimeline(start: Date, stages: [SleepStage], context: ModelContext) {
        let calendar = Calendar.current

        // Group packets by the waking-day boundary (sleep from 7 PM rolls to the next morning) so a
        // night that starts before midnight lands under the morning of waking. See
        // `Calendar.wakingDay(forSleepStart:)`.
        let dateKey = calendar.wakingDay(forSleepStart: start)

        // Attach this packet's per-minute blocks to the day's container session (create one if the
        // day is empty), deduping by block start across every session on the day. Then hand off to
        // `SleepService.reconcileWakingDay`, which re-splits the day's blocks into distinct sessions
        // (main night vs. naps separated by a >= 60 min gap) and recomputes each session's bounds.
        let allSessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let daySessions = allSessions.filter { calendar.isDate($0.date, inSameDayAs: dateKey) }
        let container = daySessions.min { $0.startAt < $1.startAt }
            ?? {
                let new = SleepSession(date: dateKey, startAt: start, endAt: start, totalMinutes: 0, syncedAt: Date())
                context.insert(new)
                return new
            }()

        // Rows to hand `reconcileWakingDay` (a just-created container isn't in `daySessions` yet).
        let sessionsForDay = daySessions.contains(where: { $0.id == container.id }) ? daySessions : daySessions + [container]

        let daySessionIds = Set(sessionsForDay.map { $0.id })
        let existingDayBlocks = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])
            .filter { daySessionIds.contains($0.sessionId) }
        var existingStarts = Set(existingDayBlocks.map { $0.startAt })
        var newBlocks: [SleepStageBlock] = []

        var offset = 0
        while offset < stages.count {
            let stage = stages[offset]
            var duration = 1
            while offset + duration < stages.count, stages[offset + duration] == stage {
                duration += 1
            }
            let blockStart = calendar.date(byAdding: .minute, value: offset, to: start) ?? start
            if !existingStarts.contains(blockStart) {
                let block = SleepStageBlock(sessionId: container.id, startAt: blockStart, startMinute: 0,
                                            durationMinutes: duration, stage: stage)
                context.insert(block)
                newBlocks.append(block)
                existingStarts.insert(blockStart)
            }
            offset += duration
        }

        // Hand the in-memory rows + blocks (incl. the ones just inserted, unsaved under the
        // coalesced flush) straight to reconcile so it needn't re-scan the whole store.
        SleepService.reconcileWakingDay(dateKey: dateKey, context: context,
                                        daySessions: sessionsForDay,
                                        dayBlocks: existingDayBlocks + newBlocks)
    }
}
