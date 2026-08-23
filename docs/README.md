# [@Malix-Labs](https://github.com/Malix-Labs) Own [Repository Template](https://docs.github.com/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)

After creating a repository from the [@Malix-Labs](https://github.com/Malix-Labs) [repository template](https://docs.github.com/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template), this file is to be cleared.
It is accessible online at <https://github.com/Malix-Labs/Template#readme>

## Usage

1. [ ] [Create a repository from this template](https://docs.github.com/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template#creating-a-repository-from-a-template)
2. [ ] Search "`github.com/Malix-Labs/<REPOSITORY>`" and replace all "`<REPOSITORY>`" by the Repository name
3. [ ] Copy all [this repository GitHub Settings](https://github.com/Malix-Labs/Template#github-settings)
4. [ ] Copy all [this repository GitHub Labels](https://github.com/Malix-Labs/Template#github-labels)

## Features

### Branching

Inspired by [Trunk-Based Development](https://trunkbaseddevelopment.com/) / [GitHub Flow](https://docs.github.com/get-started/using-github/github-flow)

- **Default (`main`/`master`)**: the single source of truth, fully protected
- **Issues (`issue/*`)**: short-lived branches for individual issues
- **Archives (`archive/**/*`)**: branches for archival purposes
- **Releases (`release/*`)**: branches for preparing a release
	- **Releases' Issues (`release/*/issue/*`)**: issue work scoped under a specific release
	- **Releases' Archives (`release/*/archive/**/*`)**: archival work scoped under a specific release

### Tags

Optimized for [Continuous Deployment (CD)](https://wikipedia.org/wiki/Continuous_deployment)

Using [Semantic Versioning (SemVer)](https://semver.org/) _(current: [v2](https://semver.org/spec/v2.0.0.html))_

Each push to the default branch should be tagged with a SemVer Tag

Non-SemVer Tags are not encouraged (at least not for long-lived purposes) but allowed

### GitHub Releases

Optimized for [Continuous Deployment (CD)](https://wikipedia.org/wiki/Continuous_deployment)

Each SemVer Tag pushed to the default branch is meant to be released

### Deployments

Optimized for [Continuous Deployment (CD)](https://wikipedia.org/wiki/Continuous_deployment)

Each GitHub Release is meant to be deployed

Deployments are meant to be executed from a pipeline (preferably GitHub Workflow) triggered by the GitHub Deployments

### [Rulesets](https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets)

[Rulesets Files Directory](/.github/Rulesets) _([download](https://download-directory.github.io/?url=https://github.com/Malix-Labs/Template/tree/main/.github/Rulesets))_

| Type   | Name                               | Status | Bypass                                                                                                                                                                   | Targets                                                               | Rules                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | File                                                                |
| ------ | ---------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Branch | Archives                           | Active | <ul><li>Repository admin _(Role)_ - Always allow</li><li>Maintainer _(Role)_ - Always allow</li><li>Dependabot _(App • github)_ - Always allow</li></ul>                 | <ul><li>+ `archive/**/*`</li><li>+ `release/*/archive/**/*`</li></ul> | <ul><li>Restrict updates</li><li>Restrict deletions</li><li>Block force pushes</li></ul>                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [File](</.github/Rulesets/Archives.json>)                           |
| Branch | Issues                             | Active | <ul><li>Repository admin _(Role)_ - Always allow</li><li>Maintainer _(Role)_ - Always allow</li><li>Dependabot _(App • github)_ - Always allow</li></ul>                 | <ul><li>+ `issue/*`</li><li>+ `release/*/issue/*`</li></ul>           | <ul><li>Restrict creations</li><li>Restrict deletions</li><li>Block force pushes</li></ul>                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [File](</.github/Rulesets/Issues.json>)                             |
| Branch | Production - Constructive          | Active | <ul><li>Repository admin _(Role)_ - Always allow</li><li>Maintainer _(Role)_ - Allow for pull requests only</li><li>Dependabot _(App • github)_ - Always allow</li></ul> | <ul><li>+ Default</li><li>+ `release/*`</li></ul>                     | <ul><li>Restrict creations</li><li>Require deployments to succeed</li><li>Require signed commits</li><li>Require a pull request before merging<ul><li>Required approvals: 0</li><li>Dismiss stale pull request approvals when new commits are pushed</li><li>Require review from Code Owners</li><li>Require approval of the most recent reviewable push</li><li>Require conversation resolution before merging</li><li>Request pull request review from Copilot</li><li>Allowed merge methods<ul><li>Merge</li><li>Squash</li><li>Rebase</li></ul></li></ul></li><li>Require code scanning results<ul><li>CodeQL - High or higher - Errors</li></ul></li></ul> | [File](</.github/Rulesets/Production - Constructive.json>)          |
| Branch | Production - Destructive           | Active | <ul><li>Repository admin _(Role)_ - Always allow</li></ul>                                                                                                               | <ul><li>+ Default</li><li>+ `release/*`</li></ul>                     | <ul><li>Restrict deletions</li><li>Block force pushes</li></ul>                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [File](</.github/Rulesets/Production - Destructive.json>)           |
| Tag    | Semantic Versioning - Constructive | Active | <ul><li>Repository admin _(Role)_</li><li>Maintainer _(Role)_</li><li>Dependabot _(App • github)_</li></ul>                                                              | <ul><li>+ `v[0-9]*`</li></ul>                                         | <ul><li>Restrict creations</li><li>Restrict updates</li><li>Require deployments to succeed</li><li>Require signatures</li></ul>                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [File](</.github/Rulesets/Semantic Versioning - Constructive.json>) |
| Tag    | Semantic Versioning - Destructive  | Active | <ul><li>Repository admin _(Role)_</li></ul>                                                                                                                              | <ul><li>+ `v[0-9]*`</li></ul>                                         | <ul><li>Restrict deletions</li><li>Block force pushes</li></ul>                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [File](</.github/Rulesets/Semantic Versioning - Destructive.json>)  |

### [GitHub Labels](https://docs.github.com/issues/using-labels-and-milestones-to-track-work/managing-labels)

| Name        | Description | Color   |
| ----------- | ----------- | ------- |
| Feature     |             | #00FF00 |
| Enhancement |             | #00FFFF |
| Fix         |             | #FF8000 |
| Update      |             | #FFFF00 |
| Deprecation |             | #FF0000 |

### [GitHub Milestones](https://docs.github.com/issues/using-labels-and-milestones-to-track-work/creating-and-editing-milestones-for-issues-and-pull-requests)

- "v1.0.0"

### [GitHub Issue and Pull Request Template](https://docs.github.com/communities/using-templates-to-encourage-useful-issues-and-pull-requests/about-issue-and-pull-request-templates)

### [GitHub Project Template](https://docs.github.com/issues/planning-and-tracking-with-projects/managing-your-project/managing-project-templates-in-your-organization#copying-a-project-as-a-template)

The best starting [GitHub project template](https://docs.github.com/issues/planning-and-tracking-with-projects/managing-your-project/managing-project-templates-in-your-organization#copying-a-project-as-a-template) for any project scale

### [GitHub Discussions Sections & Categories](https://docs.github.com/discussions/managing-discussions-for-your-community/managing-categories-for-discussions)

#### Sections

| Name        | Emoji | Categories |
| ----------- | ----- | ---------- |
| Development | 🧑‍💻     | None       |
| Usage       | ✔️     | None       |

#### Categories

| Name          | Emoji | Description | Format                | Section |
| ------------- | ----- | ----------- | --------------------- | ------- |
| Announcements | 📣     |             | Announcement          | None    |
| General       | 💬     |             | Open-ended discussion | None    |
| Questions     | ❔     |             | Question / Answer     | None    |
| Poll          | 🗳️     |             | Poll                  | None    |

### [GitHub Discussion Category Form](https://docs.github.com/discussions/managing-discussions-for-your-community/creating-discussion-category-forms)

### GitHub Actions

Optimized for [Trunk-Based Development](https://trunkbaseddevelopment.com/) / [GitHub Flow](https://docs.github.com/get-started/using-github/github-flow)

- On issue create:
	- [ ] [Create a branch named as the issue ID and link it to the created issue](https://docs.github.com/issues/tracking-your-work-with-issues/creating-a-branch-for-an-issue)
		- On first commit push to this branch:
			- [ ] Create a [draft pull request](https://docs.github.com/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/changing-the-stage-of-a-pull-request#marking-a-pull-request-as-ready-for-review) to the [parent issue](https://docs.github.com/issues/managing-your-tasks-with-tasklists/about-tasklists#about-tasklists-and-issue-hierarchy:~:text=You%20can%20create-,parent,-and%20child%20relationships) if any, else master
- On push to master:
	- [ ] Create a [draft release](https://docs.github.com/repositories/releasing-projects-on-github/managing-releases-in-a-repository#:~:text=release%20later%2C%20click-,Save%20draft,-.%20You%20can%20then) with a tag annoted with the latest semver tag incremented by one patch

### GitHub Files

Fully featued with GitHub files

### GitHub Settings

GitHub Settings cannot be embeded in a [GitHub repository template](https://docs.github.com/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) copied data, therefore, you have to [copy them manually](https://github.com/Malix-Labs/Template#github-settings)

#### General

##### Pull Requests

- Allow merge commits
  Default commit message: Pull request title
- Allow squash merging
  Default commit message: Default message
- Allow rebase merging
