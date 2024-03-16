# Contributing

Thank you for your interest in contributing!

Please review the following guidelines to help keep the project in a good shape.


## <a name="rules"></a> Gated Check-in

To prevent broken or inconsistent code from being checked-in, all Pull Request will go through a gated check-in process.
This process will check that the code builds without errors and that it meets [swift-format](https://github.com/apple/swift-format)'s standards.
Many swift-format warnings can be fixed by using the Format Source Code option that it provides in Xcode.

![image](https://github.com/MochiDiffusion/MochiDiffusion/assets/1341760/d4012424-bd54-484f-a0e2-7cb2ee20fbd3)


## <a name="commit"></a> Pull Request Commit Message Format

We have very precise rules over how our Git Pull Request commit messages must be formatted.
This format leads to **easier to read commit history**.
Note that Pull Requests are squash merged so this rule only applies to the final commit message shown in GitHub's PR page.

Each commit message consists of a **header** and a **body**.


```
<header>
<BLANK LINE>
<body>
```

The `header` is mandatory and must conform to the [Commit Message Header](#commit-header) format.

The `body` is mandatory for all commits except for those of type "docs".
When the body is present it must be at least 20 characters long and must conform to the [Commit Message Body](#commit-body) format.


#### <a name="commit-header"></a>Commit Message Header

```
<type>: <short summary>
  │       │
  │       └─⫸ Summary in present tense. Not capitalized. No period at the end.
  │
  └─⫸ Commit Type: build|ci|docs|feat|fix|perf|refactor|test
```

The `<type>` and `<summary>` fields are mandatory.


##### Type

Must be one of the following:

* **build**: Changes that affect the build system or external dependencies (Swift Packages, etc.)
* **ci**: Changes to our CI configuration files and scripts (GitHub Actions, etc)
* **docs**: Documentation only changes
* **feat**: A new feature
* **fix**: A bug fix
* **perf**: A code change that improves performance
* **refactor**: A code change that neither fixes a bug nor adds a feature


##### Summary

Use the summary field to provide a succinct description of the change:

* use the imperative, present tense: "change" not "changed" nor "changes"
* don't capitalize the first letter
* no dot (.) at the end


#### <a name="commit-body"></a>Commit Message Body

Just as in the summary, use the imperative, present tense: "fix" not "fixed" nor "fixes".

Explain the motivation for the change in the commit message body. This commit message should explain _why_ you are making the change.
You can include a comparison of the previous behavior with the new behavior in order to illustrate the impact of the change.
