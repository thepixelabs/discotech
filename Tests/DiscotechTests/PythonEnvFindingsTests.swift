import Foundation
import Testing
@testable import Discotech

/// Python virtual environments: found by the `pyvenv.cfg` inside them, whatever the folder
/// is called, and tiered by whether a recipe sits beside them. In-memory trees only.
@Suite("Findings: Python virtual environments")
struct PythonEnvFindingsTests {
    private func finding(_ id: String, in findings: [Finding]) -> Finding? { findings.first { $0.id == id } }

    /// An environment folder holding 100 MB of packages, plus `pyvenv.cfg` when `config`.
    private func env(_ name: String, config: Bool = true, _ extra: [FileNode] = []) -> FileNode {
        dirNode(name, (config ? [fileNode("pyvenv.cfg", 1)] : [])
                    + [dirNode("lib", [fileNode("packages.bin", 100 * MB)])] + extra)
    }

    private func project(_ name: String, _ entries: [FileNode]) -> FileNode {
        chain("Projects", dirNode(name, entries))
    }

    private func project(_ entries: [FileNode]) -> FileNode { project("app", entries) }

    struct Case: Sendable, CustomTestStringConvertible {
        let folder: String
        let hasConfig: Bool
        let siblings: [String]
        /// The finding id it lands in, or nil for no finding at all.
        let expected: String?
        var testDescription: String {
            "\(folder)\(hasConfig ? " with pyvenv.cfg" : "") beside \(siblings.isEmpty ? "nothing" : siblings.joined(separator: ", ")) -> \(expected ?? "no finding")"
        }
    }

    static let cases: [Case] = [
        Case(folder: ".venv", hasConfig: false, siblings: ["requirements.txt"], expected: "python-venv"),
        Case(folder: "venv", hasConfig: false, siblings: ["pyproject.toml"], expected: "python-venv"),
        Case(folder: "Venv", hasConfig: false, siblings: ["setup.py"], expected: "python-venv"),
        Case(folder: "env", hasConfig: true, siblings: ["Pipfile"], expected: "python-venv"),
        Case(folder: ".venv", hasConfig: true, siblings: ["uv.lock"], expected: "python-venv"),
        Case(folder: "virtualenv", hasConfig: true, siblings: ["poetry.lock"], expected: "python-venv"),
        Case(folder: "py", hasConfig: true, siblings: ["Pipfile.lock"], expected: "python-venv"),
        Case(folder: "py", hasConfig: true, siblings: ["setup.cfg"], expected: "python-venv"),
        Case(folder: "py", hasConfig: true, siblings: ["environment.yml"], expected: "python-venv"),
        Case(folder: "py", hasConfig: true, siblings: ["tox.ini"], expected: "python-venv"),
        Case(folder: ".venv-ml", hasConfig: true, siblings: ["requirements-dev.txt"], expected: "python-venv"),
        Case(folder: "env", hasConfig: true, siblings: ["Requirements_Test.txt"], expected: "python-venv"),
        Case(folder: "myenv", hasConfig: true, siblings: [], expected: "python-venv-no-recipe"),
        Case(folder: "myenv", hasConfig: true, siblings: ["README.md", "requirements.md"], expected: "python-venv-no-recipe"),
        Case(folder: ".venv", hasConfig: true, siblings: [], expected: "python-venv-no-recipe"),
        Case(folder: "env", hasConfig: false, siblings: ["requirements.txt"], expected: nil),
        Case(folder: "venv", hasConfig: false, siblings: [], expected: nil),
        Case(folder: "venv", hasConfig: false, siblings: ["README.md"], expected: nil),
    ]

    @Test("an environment is recognised by content and tiered by the recipe beside it", arguments: cases)
    func matching(_ c: Case) {
        let siblings = c.siblings.map { fileNode($0, 1) }
        let found = Findings.find(in: treeUnderHome([project([env(c.folder, config: c.hasConfig)] + siblings)]))
        guard let expected = c.expected else {
            #expect(found.isEmpty)
            return
        }
        #expect(found.map(\.id) == [expected])
        #expect(found.first?.nodes.map(\.name) == [c.folder])
        #expect(found.first?.tier == (expected == "python-venv" ? .safe : .review))
    }

    @Test("both findings carry their own title, reason, icon and unit")
    func specs() throws {
        let home = [project("a", [env(".venv"), fileNode("uv.lock", 1)]), project("b", [env("tools")])]
        let found = Findings.find(in: treeUnderHome(home))
        let safe = try #require(finding("python-venv", in: found))
        let review = try #require(finding("python-venv-no-recipe", in: found))
        #expect(safe.title == "Python virtual environments")
        #expect(safe.reason == "Recreated automatically the next time you set up the project.")
        #expect(review.title == "Python environments with no requirements file")
        #expect(review.reason == "Nothing next to it lists what is installed, so check before clearing it.")
        #expect(safe.icon == "leaf" && review.icon == "leaf")
        #expect(review.countLabel == "1 environment")
        #expect(safe.isCollectible && review.isCollectible)
    }

    @Test("several environments in one project are counted one by one")
    func manyInOneProject() {
        let found = Findings.find(in: treeUnderHome([project([env(".venv"), env(".venv-gpu"), env("py310"), fileNode("pyproject.toml", 1)])]))
        #expect(found.map(\.id) == ["python-venv"])
        #expect(Set(found[0].nodes.map(\.name)) == [".venv", ".venv-gpu", "py310"])
        #expect(found[0].countLabel == "3 environments")
    }

    @Test("nothing inside a matched environment is matched again")
    func notDescendedInto() {
        let nested = dirNode("site-packages", [
            dirNode("pkg", [fileNode("pyvenv.cfg", 1), dirNode("venv", [fileNode("x", 100 * MB)]), fileNode("requirements.txt", 1)]),
            dirNode("__pycache__", [fileNode("m.pyc", 100 * MB)]),
            dirNode("tool", [dirNode("node_modules", [fileNode("n.js", 100 * MB)]), fileNode("package.json", 1)]),
            fileNode("huge.bin", 2 * GB),
        ])
        let venv = env(".venv", [dirNode("lib2", [nested])])
        let found = Findings.find(in: treeUnderHome([project([venv, fileNode("requirements.txt", 1)])]))
        #expect(found.map(\.id) == ["python-venv"])
        #expect(found[0].nodes.map(\.name) == [".venv"])
        #expect(found[0].totalSize == venv.size)
        #expect(venv.size >= 400 * MB + 2 * GB)
    }

    @Test("a conda environment is counted once, by the conda rule")
    func condaNotDoubleCounted() {
        let condaEnv = dirNode("ml", [dirNode("conda-meta", [fileNode("history", 1)]), fileNode("pyvenv.cfg", 1),
                                      dirNode("lib", [fileNode("p", 200 * MB)])])
        let found = Findings.find(in: treeUnderHome([chain("miniconda3", dirNode("envs", [condaEnv]))]))
        #expect(found.map(\.id) == ["conda-envs"])
        #expect(found[0].nodes.map(\.name) == ["ml"])
    }

    @Test("a conda prefix inside a project is not a Python virtual environment")
    func projectCondaPrefixIsNotAVenv() {
        let prefix = dirNode("env", [dirNode("conda-meta", [fileNode("history", 1)]), fileNode("pyvenv.cfg", 1),
                                     dirNode("lib", [fileNode("p", 200 * MB)])])
        #expect(Findings.find(in: treeUnderHome([project([prefix, fileNode("environment.yml", 1)])])).isEmpty)
    }

    @Test("an environment directly in the home folder is Review: a file in the home folder is no recipe")
    func homeFolderEnvironmentIsReview() {
        let found = Findings.find(in: treeUnderHome([env(".venv"), fileNode("requirements.txt", 1), dirNode("venv", [fileNode("x", 100 * MB)])]))
        #expect(found.map(\.id) == ["python-venv-no-recipe"])
        #expect(found[0].nodes.map(\.name) == [".venv"])
    }

    @Test("a folder named requirements.txt is not a recipe")
    func recipeMustBeAFile() {
        let found = Findings.find(in: treeUnderHome([project([env("env"), dirNode("requirements.txt")])]))
        #expect(found.map(\.id) == ["python-venv-no-recipe"])
    }

    @Test("Safe environments come before Review ones, and Review is ordered by size with the other Review cards")
    func ordering() {
        let home: [FileNode] = [
            project("a", [env(".venv"), fileNode("requirements.txt", 1)]),
            project("b", [env("tools", [fileNode("big", 900 * MB)])]),
            chain("Library/Developer/Xcode", dirNode("Archives", [dirNode("A", [fileNode("z", 500 * MB)])])),
            chain("Library/Caches", dirNode("Homebrew", [fileNode("y", 400 * MB)])),
        ]
        let found = Findings.find(in: treeUnderHome(home))
        #expect(found.map(\.id) == ["package-caches", "python-venv", "python-venv-no-recipe", "xcode-archives"])
    }

    @Test("no node is in two findings when environments mix with other rules")
    func everyNodeAppearsOnce() {
        let home: [FileNode] = [
            project("a", [env(".venv", [dirNode("__pycache__", [fileNode("c", 60 * MB)])]), dirNode("__pycache__", [fileNode("c", 60 * MB)]),
                          fileNode("pyproject.toml", 1)]),
            project("b", [env("env", [dirNode("node_modules", [fileNode("n", 60 * MB)]), fileNode("package.json", 1)])]),
            chain("miniconda3", dirNode("envs", [dirNode("x", [dirNode("conda-meta"), env("inner")])])),
        ]
        let all = Findings.find(in: treeUnderHome(home)).flatMap(\.nodes)
        #expect(Set(all.map(ObjectIdentifier.init)).count == all.count)
        for node in all {
            #expect(!all.contains { $0 !== node && node.isDescendant(of: $0) }, "\(node.path) is inside another finding")
        }
    }

    @Test("an environment the Safety rules refuse is left out")
    func protectedEnvironmentIsExcluded() async throws {
        try await withTempTree { tree in
            for name in ["locked", "open"] {
                try tree.file("\(name)/myenv/pyvenv.cfg", bytes: 10)
                try tree.file("\(name)/requirements.txt", bytes: 10)
            }
            tree.lock("locked/myenv")
            func project(_ name: String) -> FileNode {
                dirNode(name, [env("myenv"), fileNode("requirements.txt", 1)])
            }
            let root = treeNode(root: tree.root.path, [project("locked"), project("open")]) // parents are weak: keep it alive
            let found = Findings.find(in: root)
            #expect(found.map(\.id) == ["python-venv"])
            #expect(found.first?.nodes.map(\.path) == [tree.url("open/myenv").path])
        }
    }
}
