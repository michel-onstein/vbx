import VBXCore
import Testing



/// Which statuses make a bead a record rather than work.
///
/// The rule is a function of status and nothing else, which is what keeps
/// reopening as the escape hatch: a bead closed by mistake becomes editable
/// again by becoming open again, with nothing stored and no separate lock to
/// fall out of step.
@Suite("Immutable statuses")
struct ImmutableStatusTests {

    @Test("Closed and tombstone are records; nothing else is")
    func onlyFinalStatusesAreImmutable() {
        #expect(IssueStatus.closed.isImmutable)
        // The marker left by a delete — the record it stands for is gone, so
        // there is even less to edit.
        #expect(IssueStatus.tombstone.isImmutable)

        for status: IssueStatus in [
            .open, .inProgress, .blocked, .deferred, .draft, .pinned, .hooked,
        ] {
            #expect(!status.isImmutable, "\(status.rawValue) should stay editable")
        }
    }

    @Test("An unknown status is editable, not immutable")
    func unknownStatusStaysEditable() {
        // Status is an open enum on purpose: a status this build has never
        // heard of must not silently become read-only. Refusing an edit is the
        // more surprising failure of the two, and the one nobody would think to
        // report as a bug — they would assume the bead was closed.
        #expect(!IssueStatus.unknown("triaged").isImmutable)
    }
}
