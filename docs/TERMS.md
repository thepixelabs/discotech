# Discotech Terms of Use and Risk Acknowledgement

```
TERMS_VERSION: 1
Effective date: 2026-10-06
```

---

## 1. In-app summary (agreement screen, shown above the full terms)

**Window title:** Discotech Terms of Use

**Heading:** Before you use Discotech

- Discotech moves files to the Trash. You use it entirely at your own risk.
- You decide what is moved. Check every item before you confirm.
- Keep a current backup, such as Time Machine. Without one, a mistake may be permanent.
- Suggestions and safety checks can be wrong. "Safe to clear" is not a promise.
- Moving app, Library, hidden or cloud-synced files can break apps, lose data, or remove it from your other devices.
- Once the Trash is emptied, files are usually gone for good.
- Discotech is free and provided as is, with no warranty. It sends nothing anywhere.

*(Full terms in a scrollable area below the bullets.)*

**Checkbox (unchecked by default):**
I understand that Discotech moves the files I choose to the Trash, that I am responsible for every item I choose and for my backups, and that I use Discotech entirely at my own risk.

**Buttons:** `Quit` · `Agree and Continue` (disabled until the box is checked)

---

## 2. Full terms (shown in the scrollable area, and from Help > Discotech Terms)

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

---

## 3. Delete reminder (one line in every Move to Trash confirmation)

**Primary (125 characters):**
You are responsible for every item you move. Check the list and keep a backup. Discotech is provided as is, without warranty.

**Alternative A (116 characters):**
Check every item before you move it. You use Discotech at your own risk. It is provided as is, without any warranty.

**Alternative B (104 characters):**
Your choice, your risk: check the list and keep a backup. Discotech is provided as is, without warranty.

---

## 4. Where the reminder goes

Append the chosen line, after a blank line, to the message of both alerts in
`Sources/Discotech/UI/CrateView.swift` (`CrateReviewSheet`):

1. "Move N items to the Trash?" (the final confirmation), after the size line and after the
   system/app-data line when present.
2. "Are you sure?" (the per-item prompt for system and app-data locations).

Changing only the reminder does not need a `TERMS_VERSION` bump; keep it consistent with
sections 1 and 2.

---

## 5. Implementation notes (for contributors; not shown in the app)

1. **Version constant.** Compile `TERMS_VERSION` (integer, here `1`) and the exact text of
   sections 1 and 2 into the app. Bump the integer on any change to the summary, checkbox
   sentence, button labels or full terms. Never decrease it.
2. **Stored acceptance.** On Agree, write the integer to `UserDefaults` key
   `acceptedTermsVersion`. Store nothing else about the person. Nothing leaves the Mac.
3. **Gate.** On launch, if `acceptedTermsVersion` is missing or less than `TERMS_VERSION`, show
   the agreement window and nothing else. Until accepted: no scan, no drive list, no browsing,
   no Crate, no Findings, no Settings, no Help window, no drag-and-drop or "Open" of a folder
   onto the app; menu commands that start or open anything are disabled. Quit stays available.
4. **Window.** About 520 x 640 pt. Title, heading and bullets fixed at the top; the full terms
   in a scrollable, selectable read-only text area; checkbox and buttons fixed at the bottom.
   The checkbox starts unchecked on every presentation. `Agree and Continue` is disabled until
   it is checked and is never triggered by Return while disabled. Escape does not agree.
5. **Quit and close.** `Quit` and Command-Q terminate the app without writing anything. Closing
   the agreement window (close button or Command-W) also terminates the app. The window cannot
   be minimised into a usable state behind other windows of the app, because there are none.
6. **Re-acceptance.** When a new build raises `TERMS_VERSION` above the stored value, the gate
   applies again on the next launch, with the checkbox unchecked.
7. **Read-only view.** Add "Discotech Terms" to the Help menu and a "Terms" row in Settings. Both
   open the full terms (section 2) read-only, with the version number and the accepted version,
   no checkbox, and a Close button only.
8. **No bypass in release builds.** DEBUG self-test hooks may pre-accept (for example a launch
   argument `-acceptedTermsVersion 1`, which `UserDefaults` honours from the argument domain);
   that path is for contributors only and is not user-facing. Release builds must have no environment-variable
   or hidden-key bypass.
9. **Test.** A test that fails if the shown text changes while `TERMS_VERSION` does not (for
   example a hash of the bundled text pinned next to the constant).
