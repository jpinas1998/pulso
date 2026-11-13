import Foundation

struct Worktree: Identifiable {
    var path: String
    var repo: String
    var branch: String?
    var isMain = false
    var detached = false
    var prunable = false
    var lastCommit: Date?
    var subject = ""
    var changes = 0
    var ahead = 0
    var behind = 0
    var upstreamGone = false
    var merged = false
    var head = ""
    /// Rama recién creada: su punta es un commit de la rama base (git la da por "fusionada" sin serlo).
    var fresh = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var repoName: String { (repo as NSString).lastPathComponent }
    static let longLived: Set<String> = ["main", "master", "develop", "dev", "staging", "production", "release"]

    /// Candidato a borrar: no es el principal ni una rama de larga duración, no tiene cambios, y su rama
    /// ya se borró en el remoto o está fusionada, tiene commits propios y lleva más de un día sin commits.
    var isCandidate: Bool {
        guard !isMain, changes == 0, let b = branch, !Self.longLived.contains(b), !b.hasPrefix("release/") else { return false }
        if upstreamGone { return true }
        let old = lastCommit.map { Date().timeIntervalSince($0) > 86400 } ?? false
        return merged && !fresh && old
    }
}

@MainActor
final class WorktreeService: ObservableObject {
    @Published private(set) var worktrees: [Worktree] = []
    @Published private(set) var loading = false
    @Published private(set) var fetching = false
    @Published private(set) var lastLoad: Date?
    @Published private(set) var busy = Set<String>()

    var onChanged: ((String) -> Void)?

    private var gitEnv: [String: String] {
        var e = ShellEnv.userEnvironment
        e["GIT_OPTIONAL_LOCKS"] = "0"        // nunca bloquear el índice del usuario
        e["GIT_TERMINAL_PROMPT"] = "0"
        return e
    }
    private var git: String { ShellEnv.which("git") ?? "/usr/bin/git" }

    var repos: [String] { Array(Set(worktrees.map(\.repo))).sorted() }

    func refreshIfStale() {
        if lastLoad.map({ Date().timeIntervalSince($0) > 600 }) ?? true { refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let git = self.git, env = gitEnv
        DispatchQueue.global(qos: .utility).async {
            let list = Self.load(git: git, env: env)
            DispatchQueue.main.async { [weak self] in
                self?.worktrees = list
                self?.loading = false
                self?.lastLoad = Date()
            }
        }
    }

    /// git fetch --prune en cada repo (para saber qué ramas se fusionaron y borraron en remoto).
    func fetchAll() {
        guard !fetching else { return }
        fetching = true
        let git = self.git, env = gitEnv, repos = self.repos
        DispatchQueue.global(qos: .utility).async {
            for r in repos { _ = Subprocess.run(git, ["-C", r, "fetch", "--prune", "--quiet"], timeout: 90, env: env) }
            DispatchQueue.main.async { [weak self] in
                self?.fetching = false
                self?.lastLoad = nil
                self?.refresh()
            }
        }
    }

    /// Elimina el worktree con `git worktree remove` y, si se pide, también su rama.
    func remove(_ wts: [Worktree], force: Bool, deleteBranch: Bool) {
        let targets = wts.filter { !$0.isMain && !busy.contains($0.path) }
        guard !targets.isEmpty else { return }
        busy.formUnion(targets.map(\.path))
        let git = self.git, env = gitEnv
        DispatchQueue.global(qos: .utility).async {
            var errors: [String] = []
            var removed = 0
            for wt in targets {
                var args = ["-C", wt.repo, "worktree", "remove"]
                if force { args.append("--force") }
                args.append(wt.path)
                let r = Subprocess.run(git, args, timeout: 120, env: env)
                guard r.code == 0 else { errors.append("\(wt.name): \(r.output.split(separator: "\n").last ?? "")"); continue }
                removed += 1
                if deleteBranch, let b = wt.branch {
                    // Las ramas fusionadas con squash no cuentan como "merged" para git: si el remoto ya la borró, -D.
                    let flag = (wt.merged && !wt.upstreamGone) ? "-d" : (wt.upstreamGone ? "-D" : "-d")
                    _ = Subprocess.run(git, ["-C", wt.repo, "branch", flag, b], timeout: 30, env: env)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy.subtract(targets.map(\.path))
                let msg = errors.isEmpty ? "Eliminado\(removed == 1 ? "" : "s") \(removed) worktree\(removed == 1 ? "" : "s")"
                    : "Errores: " + errors.joined(separator: " · ")
                self.onChanged?(msg)
                self.lastLoad = nil
                self.refresh()
            }
        }
    }

    // MARK: - Lectura (en segundo plano)

    nonisolated private static func load(git: String, env: [String: String]) -> [Worktree] {
        let root = NSHomeDirectory() + "/Documents/projects"
        let found = Subprocess.run("/usr/bin/find", [root, "-maxdepth", "4", "(", "-name", "node_modules", "-o", "-name", "build",
                                                     "-o", "-name", ".dart_tool", "-o", "-name", ".venv", ")", "-prune",
                                                     "-o", "-name", ".git", "-type", "d", "-print"], timeout: 30, env: env)
        let repos = found.output.split(separator: "\n").map { String($0.dropLast(5)) }   // quita "/.git"

        var all: [Worktree] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: repos.count) { i in
            let wts = loadRepo(repos[i], git: git, env: env)
            lock.lock(); all += wts; lock.unlock()
        }
        return all
    }

    nonisolated private static func loadRepo(_ repo: String, git: String, env: [String: String]) -> [Worktree] {
        let list = Subprocess.run(git, ["-C", repo, "worktree", "list", "--porcelain"], timeout: 20, env: env).output
        var wts: [Worktree] = []
        var cur: Worktree?
        for line in list.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let c = cur { wts.append(c) }
                cur = Worktree(path: String(line.dropFirst(9)), repo: repo)
                cur?.isMain = wts.isEmpty
            } else if line.hasPrefix("HEAD ") {
                cur?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch refs/heads/") {
                cur?.branch = String(line.dropFirst(18))
            } else if line == "detached" {
                cur?.detached = true
            } else if line.hasPrefix("prunable") {
                cur?.prunable = true
            }
        }
        if let c = cur { wts.append(c) }
        guard wts.count >= 2 else { return [] }        // solo repos con worktrees

        // Rama base (origin/HEAD → main/develop) y ramas fusionadas en ella.
        var base = Subprocess.run(git, ["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], timeout: 10, env: env)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "main" }
        let merged = Set(Subprocess.run(git, ["-C", repo, "branch", "--merged", base, "--format=%(refname:short)"], timeout: 20, env: env)
            .output.split(separator: "\n").map(String.init))
        // Commits de la rama base: una rama cuya punta es uno de ellos no tiene commits propios (recién creada).
        let baseShas = Set(Subprocess.run(git, ["-C", repo, "rev-list", "--first-parent", "-n", "400", base], timeout: 20, env: env)
            .output.split(separator: "\n").map(String.init))
        var track: [String: String] = [:]
        for l in Subprocess.run(git, ["-C", repo, "for-each-ref", "--format=%(refname:short)%09%(upstream:track)", "refs/heads"], timeout: 20, env: env)
            .output.split(separator: "\n") {
            let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
            if p.count == 2 { track[p[0]] = p[1] }
        }

        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: wts.count) { i in
            var w = wts[i]
            guard !w.prunable, FileManager.default.fileExists(atPath: w.path) else { return }
            let log = Subprocess.run(git, ["-C", w.path, "log", "-1", "--format=%ct%x09%s"], timeout: 15, env: env).output
            let parts = log.split(separator: "\t", maxSplits: 1).map(String.init)
            if let t = parts.first.flatMap(Double.init) { w.lastCommit = Date(timeIntervalSince1970: t) }
            if parts.count > 1 { w.subject = parts[1] }
            w.changes = Subprocess.run(git, ["-C", w.path, "status", "--porcelain"], timeout: 30, env: env)
                .output.split(separator: "\n").count
            if let b = w.branch {
                w.merged = merged.contains(b) && !w.isMain
                w.fresh = baseShas.contains(w.head)
                let t = track[b] ?? ""
                w.upstreamGone = t.contains("gone")
                if let r = t.range(of: #"ahead (\d+)"#, options: .regularExpression) { w.ahead = Int(t[r].split(separator: " ")[1]) ?? 0 }
                if let r = t.range(of: #"behind (\d+)"#, options: .regularExpression) { w.behind = Int(t[r].split(separator: " ")[1]) ?? 0 }
            }
            lock.lock(); wts[i] = w; lock.unlock()
        }
        return wts
    }
}
