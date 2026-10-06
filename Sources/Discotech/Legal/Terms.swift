import Foundation

/// The Terms of Use and Risk Acknowledgement shown before the app can be used.
///
/// Source of truth: `docs/TERMS.md`. Every string below is copied from it word for word
/// (section 1 for the agreement screen, section 2 for the full terms, section 3 for the
/// delete reminder). When any of the summary, the checkbox sentence, the button labels or
/// the full terms change there, copy the new text here AND raise `version` to match its
/// `TERMS_VERSION` line, so everyone who accepted the old text is asked again. Never lower
/// it. Changing only `deleteReminder` needs no bump.
enum Terms {
    /// `TERMS_VERSION` in docs/TERMS.md.
    static let version = 1

    // MARK: Section 1: agreement screen

    static let windowTitle = "Discotech Terms of Use"
    static let heading = "Before you use Discotech"
    static let summary = [
        "Discotech moves files to the Trash. You use it entirely at your own risk.",
        "You decide what is moved. Check every item before you confirm.",
        "Keep a current backup, such as Time Machine. Without one, a mistake may be permanent.",
        "Suggestions and safety checks can be wrong. \"Safe to clear\" is not a promise.",
        "Moving app, Library, hidden or cloud-synced files can break apps, lose data, or remove it from your other devices.",
        "Once the Trash is emptied, files are usually gone for good.",
        "Discotech is free and provided as is, with no warranty. It sends nothing anywhere.",
    ]
    static let checkbox = "I understand that Discotech moves the files I choose to the Trash, that I am responsible for every item I choose and for my backups, and that I use Discotech entirely at my own risk."
    static let quitButton = "Quit"
    static let agreeButton = "Agree and Continue"

    // MARK: Section 3: delete reminder

    /// One line for every Move to Trash confirmation (docs/TERMS.md section 3, primary).
    static let deleteReminder = "You are responsible for every item you move. Check the list and keep a backup. Discotech is provided as is, without warranty."

    // MARK: Section 2: full terms

    /// The full terms, as inline Markdown (bold only); line breaks are significant.
    static let fullText = """
    **Discotech Terms of Use and Risk Acknowledgement**
    Version 1. Effective 2026-10-06.

    **USE AT YOUR OWN RISK. Discotech moves files and folders to the macOS Trash. Choosing the wrong items can break apps or lose data. You alone decide what is moved, and you alone carry that risk.**

    **1. What Discotech does**
    1.1 Discotech scans a disk or folder you choose and shows what uses space. The scan reads file names, locations and sizes, not file contents.
    1.2 Items in the Crate move to the macOS Trash only after you confirm "Move to Trash" in the review window. Discotech never empties the Trash and never deletes files permanently itself. Items in the Trash can be put back until it is emptied.

    **2. Your responsibility**
    2.1 You are solely responsible for reviewing every item before you move it.
    2.2 You are responsible for keeping a current backup, such as Time Machine, before you move anything.
    2.3 Do not move files you are not entitled to remove.

    **3. Suggestions and safety checks are not guarantees**
    3.1 Findings suggestions are guesses from names, locations, file types and sizes, and can be wrong. "Safe to clear" means usually rebuilt or downloaded again when needed, not safe on your Mac. "Review first" items may be personal and are not rebuilt.
    3.2 Discotech refuses some items, such as macOS system folders, disk roots, your home folder, protected and locked items, and asks again before each item in a system or app-data location. These checks reduce risk but do not cover everything that matters, and they can fail.
    3.3 Sizes and space figures are estimates from a scan at one moment. Space may not be freed until the Trash is emptied, or at all if links, snapshots or apps keep the data.

    **4. Higher-risk locations**
    4.1 Moving items from Library, app-data, Applications, hidden or system folders can stop apps working, erase settings, accounts or keys, and affect other users of the Mac.
    4.2 Discotech does not detect cloud-synced folders. Moving an item from one may remove it from the cloud and your other devices too. Check how your sync service handles deletions.
    4.3 On external or network disks, the Trash may live on that disk, or there may be none. A moved item may then be lost with that disk.
    4.4 Once the Trash is emptied, items are usually gone for good.

    **5. No warranty**
    Discotech is provided "as is", without warranty of any kind, express or implied, including merchantability, fitness for a particular purpose and non-infringement, as the MIT License also states. We do not promise it is error-free, that its suggestions are correct, or that it frees any amount of space.

    **6. Limitation of liability**
    To the maximum extent permitted by law, PixeLabs and Discotech's contributors are not liable for any loss or damage from your use of Discotech, including loss of data, files, settings or work, damage to apps or your system, downtime, lost profits, or any indirect, incidental, special or consequential damage, even if told it was possible.

    **7. Rights you cannot waive**
    Nothing in these terms limits any right you have by law that cannot be waived or limited by agreement, including consumer law where you live. If any part cannot be enforced, the rest still applies.

    **8. The MIT License**
    Discotech's source code is licensed under the MIT License (the LICENSE file). These terms restrict no right the MIT License grants; they are a risk acknowledgement for running the app. On the software licence, the MIT License governs.

    **9. Privacy**
    Discotech contains no networking code and sends nothing anywhere. Scans stay in memory and are discarded when you quit or rescan. Only your settings, including which version of these terms you accepted, are saved on your Mac. Full Disk Access is optional; it lets Discotech see protected folders such as Mail, Messages and Safari, which widens what you can select and move.

    **10. Downloads**
    Current releases are ad-hoc signed and not notarized by Apple, so macOS warns on first launch. Install Discotech only from its official project page.

    **11. Changes**
    If these terms change, Discotech shows them again and you must accept the new version to keep using it.

    **12. Contact**
    Discotech is published by PixeLabs. Questions and problems: https://github.com/thepixelabs/discotech/issues
    """

    /// `fullText` rendered: bold runs kept, every line break kept, nothing turned into a link
    /// (the terms are read, not clicked through).
    static let fullTextAttributed: AttributedString = {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: fullText, options: options)) ?? AttributedString(fullText)
    }()
}
