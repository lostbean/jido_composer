# Local issue tracker

## Layout

- Feature documents live at `issues/<feature-slug>/PRD.md`.
- Work items live at `issues/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` within each feature.
- Each work item has `Status: <state>` and `Category: <category>` near its title.

## Vocabulary

| Role            | Stored label    |
| --------------- | --------------- |
| needs-triage    | needs-triage    |
| needs-info      | needs-info      |
| ready-for-agent | ready-for-agent |
| ready-for-human | ready-for-human |
| in-progress     | in-progress     |
| done            | done            |
| wontfix         | wontfix         |
| bug             | bug             |
| enhancement     | enhancement     |

## Comments

- Comments are appended under a `## Comments` heading in the work item.
- AI-authored comments use the prefix `AI-authored:`.

## Retired tracking

- OpenSpec records and integrations were removed from the working tree at the owner's request.
- The removed files remain recoverable from Git history.
- Their task lists had no unchecked items when removed; this is not a new verification of their implementation.
- No completed historical task was reopened or copied into this tracker.
