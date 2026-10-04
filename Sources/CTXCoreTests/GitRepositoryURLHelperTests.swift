import CTXCore
import Foundation

func runGitRepositoryURLHelperTests() {
    let ssh1 = "git@git.example.com:org/argocd-apps.git"
    let web1 = GitRepositoryURLHelper.webURL(from: ssh1)
    assert(web1?.absoluteString == "https://git.example.com/org/argocd-apps", "Must convert SSH to HTTPS")

    let web1WithBranch = GitRepositoryURLHelper.webURL(from: ssh1, revision: "release/argocd-sync")
    assert(web1WithBranch?.absoluteString == "https://git.example.com/org/argocd-apps/tree/release/argocd-sync", "Must append branch tree")

    let web1WithCommit = GitRepositoryURLHelper.webURL(from: ssh1, revision: "4c38b07")
    assert(web1WithCommit?.absoluteString == "https://git.example.com/org/argocd-apps/commit/4c38b07", "Must append commit hash")

    let https1 = "https://github.com/kubernetes/kubernetes.git"
    let web2 = GitRepositoryURLHelper.webURL(from: https1, revision: "main")
    assert(web2?.absoluteString == "https://github.com/kubernetes/kubernetes/tree/main", "Must convert HTTPS with branch")

    let ssh2 = "ssh://git@gitlab.com/group/project.git"
    let web3 = GitRepositoryURLHelper.webURL(from: ssh2)
    assert(web3?.absoluteString == "https://gitlab.com/group/project", "Must convert ssh:// prefix")
}
