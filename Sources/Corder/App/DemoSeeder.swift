import Foundation

/// Seeds the Library with a handful of demo meetings on first launch
/// so the user lands on a populated dashboard, full transcripts,
/// realistic titles, varied lengths. Runs **once per user** (guarded
/// by `AppSettings.demoDataSeeded`).
///
/// Why fake meetings? The Library is the whole product surface; an
/// empty list on first open teaches nothing. Five canned sessions
/// double as a tour: the user clicks around, sees speakers, summaries,
/// search highlights, archive controls, without recording anything.
///
/// What we DON'T fake:
///   - audio / video files (`videoPath` and `audioPath` are stable
///     paths under the recordings dir, but no actual WAV exists, ///     playback returns 404 gracefully, transcript still renders).
///   - real Gemini calls, we hand-author the transcripts.
@MainActor
enum DemoSeeder {

    /// Bump this whenever the template content changes in a way we
    /// want delivered to existing installs (titles, language, summary
    /// shape). The seeder deletes the previously seeded rows by id
    /// and re-inserts the current set when the stored version is
    /// lower than this number.
    static let currentSeedVersion: Int = 3

    /// One-shot sweep for existing installs that already received the
    /// demo rows: drop them and reset the flags so re-launches don't
    /// re-create them. A user landing on Corder wants an empty Library,
    /// not someone else's hand-written "Daily standup".
    static func removeAll(repo: MeetingRepository) {
        let seededIds = AppSettings.demoSeededIDs
        var dropped = 0
        for id in seededIds {
            if (try? repo.deleteMeeting(id: id)) != nil { dropped += 1 }
        }
        // Title sweep too, in case older builds left rows without the
        // stored id list (v1 didn't track them).
        let knownTitles: Set<String> = [
            "Daily standup",
            "1:1 with Dima, quarterly plan",
            "All hands, Q1 review",
            // v1 (russian, in case any v1 installs survive)
            "Standup, что блокирует и кто блестит",
            "1:1 с Димой, план на квартал",
            "All-hands, итоги Q1",
        ]
        if let all = try? repo.listMeetings() {
            for row in all where row.title.map(knownTitles.contains) == true {
                if (try? repo.deleteMeeting(id: row.id)) != nil { dropped += 1 }
            }
        }
        AppSettings.setDemoSeededIDs([])
        AppSettings.setDemoDataSeeded(true)
        AppSettings.setDemoDataSeedVersion(Self.currentSeedVersion)
        if dropped > 0 {
            FileLogger.log("DemoSeeder.removeAll: dropped \(dropped) demo rows")
        }
    }

    /// Run the one-shot seed (or re-seed if the content version has
    /// moved). Existing user recordings are never touched: only the
    /// ids DemoSeeder owns get deleted on a version bump.
    static func seedIfNeeded(repo: MeetingRepository) {
        let stored = AppSettings.demoDataSeedVersion
        let seeded = AppSettings.demoDataSeeded
        if seeded && stored >= Self.currentSeedVersion { return }

        // Re-seed path: drop previously seeded rows by their stored
        // ids. Anything DemoSeeder did not insert (real user
        // recordings) is left alone.
        if seeded {
            let old = AppSettings.demoSeededIDs
            for id in old { try? repo.deleteMeeting(id: id) }
            FileLogger.log("DemoSeeder: removed \(old.count) old seed rows (version \(stored) → \(Self.currentSeedVersion))")

            // Title-based sweep for every previous template revision.
            // The `demoSeededIDs` array was introduced in v2, so v1
            // installs left no ids to delete by; and even some v2
            // installs may have skipped the array if they crashed
            // mid-seed. Matching on the exact known titles is safe:
            // a user would have to recreate one of these strings
            // verbatim by hand to trigger an accidental delete.
            let legacyTitles: Set<String> = [
                // v1 (russian)
                "Standup, что блокирует и кто блестит",
                "1:1 с Димой, план на квартал",
                "All-hands, итоги Q1",
            ]
            var swept = 0
            if let all = try? repo.listMeetings() {
                for row in all where row.title.map(legacyTitles.contains) == true {
                    try? repo.deleteMeeting(id: row.id)
                    swept += 1
                }
            }
            if swept > 0 {
                FileLogger.log("DemoSeeder: swept \(swept) legacy rows by title")
            }
        }

        let now = Date()
        var inserted = 0
        var newIDs: [String] = []
        for template in templates {
            do {
                let id = try insert(template: template, now: now, repo: repo)
                newIDs.append(id)
                inserted += 1
            } catch {
                FileLogger.log("DemoSeeder: failed to insert \(template.title): \(error)")
            }
        }

        AppSettings.setDemoSeededIDs(newIDs)
        AppSettings.setDemoDataSeeded(true)
        AppSettings.setDemoDataSeedVersion(Self.currentSeedVersion)
        FileLogger.log("DemoSeeder: seeded \(inserted) demo meetings (version \(Self.currentSeedVersion))")
    }

    // MARK: - Insertion

    @discardableResult
    private static func insert(template: DemoTemplate,
                                now: Date,
                                repo: MeetingRepository) throws -> String {
        let meetingId = UUID().uuidString
        let startedAt = Int64(now.addingTimeInterval(-template.ageSeconds).timeIntervalSince1970 * 1000)
        let endedAt   = startedAt + Int64(template.durationSec) * 1000
        let dir = AppPaths.recordingsDir.appendingPathComponent(meetingId, isDirectory: true)

        var meeting = Meeting(
            id: meetingId,
            startedAt: startedAt,
            videoPath: dir.appendingPathComponent("video.mov").path,
            audioPath: dir.appendingPathComponent("audio.wav").path,
            status: .ready
        )
        meeting.endedAt = endedAt
        meeting.durationMs = Int64(template.durationSec) * 1000
        meeting.transcribedAt = endedAt + 5_000   // pretend transcription finished a moment later
        // Stamp `viewed_at` so demo rows render as already-read (no
        // accent-gold "unseen" titles). They are samples to explore,
        // not new notifications.
        meeting.viewedAt = endedAt + 10_000
        meeting.title = template.title
        meeting.summary = template.summary
        try repo.insertMeeting(meeting)

        // Speakers, assign each a colour. The frontend palette
        // cycles through these so adjacent rows look distinct.
        let speakerColours = ["#1F7A4F", "#3A7BD5", "#D58A3A", "#8E47D1", "#D14773"]
        var speakerIDs: [String: String] = [:]
        for (i, label) in template.speakers.enumerated() {
            let id = UUID().uuidString
            speakerIDs[label] = id
            let colour = speakerColours[i % speakerColours.count]
            try repo.insertSpeaker(Speaker(
                id: id,
                meetingId: meetingId,
                label: label,
                colorHex: colour
            ))
        }

        // Segments, author them so timestamps line up with the
        // template duration. Each line gets ~`duration / lineCount`
        // milliseconds; gaps between speakers are short.
        let durationMs = Int64(template.durationSec) * 1000
        let perLine = durationMs / Int64(max(1, template.transcript.count))
        var cursor: Int64 = 0
        for line in template.transcript {
            guard let speakerId = speakerIDs[line.speaker] else { continue }
            let end = min(cursor + perLine - 100, durationMs)
            try repo.insertSegment(Segment(
                meetingId: meetingId,
                speakerId: speakerId,
                startMs: cursor,
                endMs: end,
                text: line.text
            ))
            cursor = end + 200
        }
        return meetingId
    }

    // MARK: - Templates

    private struct DemoTemplate {
        let title: String
        let ageSeconds: TimeInterval   // how long ago (from now) this meeting "happened"
        let durationSec: Int
        let speakers: [String]         // ordered, first one = user
        let summary: String?
        let transcript: [DemoLine]
    }

    private struct DemoLine {
        let speaker: String
        let text: String
    }

    /// Three demo meetings spread across the last week: a short
    /// multi-speaker daily standup, a medium 1:1, and a long company
    /// all hands. Content is hand-authored to read as useful sample
    /// material, not lorem ipsum filler. English only, no em-dashes,
    /// dashes used sparingly (only inside well-established compound
    /// terms like "follow-up").
    private static let templates: [DemoTemplate] = [

        // 1. Daily standup. Short, four speakers, light content.
        DemoTemplate(
            title: "Daily standup",
            ageSeconds: 2 * 60 * 60,          // 2 hours ago
            durationSec: 8 * 60,
            speakers: ["You", "Anya", "Stas", "Lena"],
            summary: """
            ### Highlights
            - **Anya** wrapped up SDK onboarding. Schema migration still to ship.
            - **Stas** is on a payment regression, fix expected before noon.
            - **Lena** is at a conference and back on Wednesday.

            ### Action items
            - You: merge PR #482 before lunch.
            - Anya: deploy the migration once Stas ships the fix.
            """,
            transcript: [
                DemoLine(speaker: "You",  text: "Okay, let's go. Anya, what do you have today?"),
                DemoLine(speaker: "Anya", text: "I closed the SDK onboarding work. Schema migration still has to ship to staging."),
                DemoLine(speaker: "Anya", text: "If Stas lands the payment fix today I will deploy right after him."),
                DemoLine(speaker: "Stas", text: "The bug is in decimal rounding on euro amounts. Fixed locally, running tests now."),
                DemoLine(speaker: "Stas", text: "Should be merged before noon unless something blows up."),
                DemoLine(speaker: "You",  text: "Lena, are you with us?"),
                DemoLine(speaker: "Lena", text: "I am at the conference until Wednesday. Async on Slack."),
                DemoLine(speaker: "Lena", text: "Ping me if anything is burning."),
                DemoLine(speaker: "You",  text: "Okay. I will merge PR 482 before lunch. We are done."),
            ]
        ),

        // 2. 1:1 with manager. Medium length, two speakers.
        DemoTemplate(
            title: "1:1 with Dima, quarterly plan",
            ageSeconds: 24 * 60 * 60,
            durationSec: 38 * 60,
            speakers: ["You", "Dima"],
            summary: """
            ### Quarter goals
            - Close the migration to the new billing pipeline.
            - Stabilise flaky tests (currently 4 to 7 percent rate, target 1 percent).
            - Hire one junior engineer.

            ### Growth
            - **Dima** recommends a distributed systems course on Coursera.
            - Shadow call with the Stripe team booked for two weeks out.

            ### Follow-up
            - You will send a draft of the quarterly OKRs by Friday.
            """,
            transcript: [
                DemoLine(speaker: "Dima", text: "Hey. How are things in general?"),
                DemoLine(speaker: "You",  text: "Pretty good. We shipped the big release, finally exhaled. Cleaning up tech debt this week."),
                DemoLine(speaker: "Dima", text: "Nice. Let's talk about the quarter. What is on your mind?"),
                DemoLine(speaker: "You",  text: "Three things. Billing migration is the biggest item, and it is blocking the analytics team."),
                DemoLine(speaker: "You",  text: "Second, flaky tests. We burn about five hours a week on retries."),
                DemoLine(speaker: "You",  text: "Third, I want to bring on a junior. Scaling alone is rough."),
                DemoLine(speaker: "Dima", text: "On the junior, I have two candidates from the last batch. I will share their profiles."),
                DemoLine(speaker: "Dima", text: "For billing, the Stripe team has done something similar. I can set up a shadow call."),
                DemoLine(speaker: "You",  text: "That would help. Two weeks out?"),
                DemoLine(speaker: "Dima", text: "Two weeks. Also, take a look at the distributed systems course on Coursera. I went through it recently, very relevant."),
                DemoLine(speaker: "You",  text: "Noted. Anything else on growth?"),
                DemoLine(speaker: "Dima", text: "I want to see you more active in architecture review. You listen well, but your input is missing."),
                DemoLine(speaker: "You",  text: "Got it. I will prep ahead of those sessions."),
                DemoLine(speaker: "Dima", text: "Good. Send me a draft of the OKRs by Friday and we will close on them next week."),
            ]
        ),

        // 3. All hands. Long, business content, many speakers.
        DemoTemplate(
            title: "All hands, Q1 review",
            ageSeconds: 6 * 24 * 60 * 60,
            durationSec: 72 * 60,
            speakers: ["You", "Dima", "CEO", "CTO", "Head of Growth"],
            summary: """
            ### Q1 by the numbers
            - **ARR**: $4.2M to $5.8M (+38%)
            - **Gross margin**: 78 percent (stable)
            - **Team**: 32 to 41 people, six more on the Q2 plan

            ### What went well
            - Enterprise SKU took off, two contracts at $200K per year.
            - Onboarding conversion went from 23 percent to 31 percent after the new tutorial.

            ### What hurt
            - SMB churn rose by 1.4 percentage points.
            - Support load doubled while the team stayed the same size.

            ### Q2 focus
            - Bring SMB churn back to Q4 baseline.
            - Launch the API tier in October.
            - Hire a Director of Customer Success.
            """,
            transcript: [
                DemoLine(speaker: "CEO",            text: "Hi everyone. Q1 is closed. We will go through the numbers, then by team, then questions."),
                DemoLine(speaker: "CEO",            text: "ARR went from $4.2 million to $5.8 million. Plus 38 percent quarter over quarter, ahead of plan."),
                DemoLine(speaker: "Head of Growth", text: "The main driver was the Enterprise SKU. Two contracts at $200K each. Pipeline for Q2 looks even better."),
                DemoLine(speaker: "Head of Growth", text: "Onboarding conversion went from 23 percent to 31 percent thanks to the new tutorial. Big credit to the product team."),
                DemoLine(speaker: "CTO",            text: "Infra wise, we held three times peak traffic during the launch without any outages."),
                DemoLine(speaker: "CTO",            text: "Tech debt is piling up though. I want to dedicate Q2 to refactoring the billing pipeline."),
                DemoLine(speaker: "CEO",            text: "Now the not so great news. SMB churn went up by 1.4 percentage points."),
                DemoLine(speaker: "CEO",            text: "Support load doubled versus Q4, but the support team did not grow."),
                DemoLine(speaker: "Dima",           text: "On support, the main spikes are billing edge cases and the Salesforce integration."),
                DemoLine(speaker: "Dima",           text: "If the CTO team unblocks billing, half of the tickets go away."),
                DemoLine(speaker: "CEO",            text: "Q2 focus. Bring SMB churn back to Q4 baseline. Launch the API tier in October. Hire a Director of Customer Success."),
                DemoLine(speaker: "You",            text: "Who is going to lead the API tier launch?"),
                DemoLine(speaker: "CTO",            text: "Dima and I. We are pulling a small team together."),
                DemoLine(speaker: "CEO",            text: "Questions in the chat, we will reply async. That is it. Thanks, everyone."),
            ]
        ),
    ]
}
