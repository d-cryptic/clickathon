# Click-a-thon '26 Submissions

Welcome! This repository collects all project submissions for **Click-a-thon 2026**.

## How to Submit

1. Review your partner track's **submission guidelines** — each partner has
  track-specific guidelines for better evaluation, which apply **in addition to**
   the common requirements below:
  - **Atlys** — [ATLYS_SUBMISSION_GUIDELINES.md](ATLYS_SUBMISSION_GUIDELINES.md)
  - **SonyLIV** — [SONYLIV_SUBMISSION_GUIDELINES.md](SONYLIV_SUBMISSION_GUIDELINES.md)
  - **InMobi** — [INMOBI_SUBMISSION_GUIDELINES.md](INMOBI_SUBMISSION_GUIDELINES.md)
   Where a partner's guidelines specify something more specific (e.g. artifacts,
   architecture format, video length), the partner track's guidelines take precedence.
2. **Fork** this repository.
3. Create a folder at the root of the repo, named after your **team** - your team name
  is your unique identifier across all tracks:
4. Inside your folder, the following are **mandatory for all submissions**, regardless
  of track:
  - **Project source code** (**mandatory**)
  - `README.md` (**mandatory**) — must include a **hosted demo link**, and this demo link itself must cover the details required by your track's submission guidelines ([Atlys](ATLYS_SUBMISSION_GUIDELINES.md) ·
  [SonyLIV](SONYLIV_SUBMISSION_GUIDELINES.md) ·
  [InMobi](INMOBI_SUBMISSION_GUIDELINES.md)) — see the
  [template below](#submission-readme-template)
  - **Architecture** (**mandatory**) — Atlys teams follow the architecture section in
  their [track guidelines](ATLYS_SUBMISSION_GUIDELINES.md); other tracks may cover
  it within the `README.md` or as separate screenshots/diagrams
  - **Demo video** (**mandatory**) — a recorded video, 2–3 minutes
  - **Pitch deck in PDF format** (**mandatory**) — e.g. `pitch-deck.pdf`
5. Add anything else your track's guidelines require (artifacts, traces, probe
  outputs, etc.).
6. Open a **pull request** against this repository with the title:
  ```
   [Submission] Your Team Name
  ```



## Submission README Template

Your team's `README.md` should cover:

```markdown
# Team Name

## Track
Atlys / SonyLIV / InMobi

## Project
Your project's name and a one-line tagline.

## Team Members
- Name (GitHub handle)

## What it does
A short description of your project.

## Hosted Demo
Link to your live, hosted demo (mandatory). The demo must cover the details
required by your track's submission guidelines.

## Demo Video
Link to your recorded 2–3 minute demo video (mandatory).

## Architecture
Diagram and/or explanation of your architecture (Atlys teams: follow your
track guidelines instead).

## How we built it
Tech stack, tools, and anything interesting about the implementation.

## How to run it
Step-by-step instructions to run the project locally.
```



## Using ClickStack, Langfuse, or LibreChat?

These tools run as services outside your repo, so judges only see what you capture. If your solution uses any of them, include the following in your team's folder - "we had it running" is not evidence.

**For every tool you use:**

- **Commit the wiring** — deployment config (e.g. `docker-compose.yml` / Helm),
an `.env.example` with **secrets redacted**, and the integration code itself
(SDK setup, OTel collector config, custom endpoints). Judges must be able to see
*how* it's connected, even if they don't redeploy it.
- **Show it live** in your hosted demo and demo video - a screenshot alone is not proof of integration.
- **Explain its role** in your README's architecture section: what part of the
pipeline runs through the tool. Superficial inclusion (installed but not part of
the actual workflow) scores nothing on the ClickHouse & OSS Stack criterion.

**Tool-specific evidence:**

- **Langfuse** — share traces as **public share links**, or export them as JSON
into your submission folder. Do not rely on judges logging into your Langfuse
project. Traces must correspond to the actual graded runs (see your track's
guidelines for which runs require traces).
- **ClickStack** — include your OTel collector / ingestion config, state which
ClickHouse service and tables it writes to, and capture the dashboards or
searches you actually used (screenshots in the README plus a live walkthrough
in the video).
- **LibreChat** — commit your `librechat.yaml` and any custom endpoint, agent, or  
tool definitions (keys redacted). If LibreChat is your product UI, the hosted  
demo link should point to it — provide test credentials for judges in your  
README, or demonstrate the full chat flow in the video.

## Rules

- All code must be written during the hackathon period.
- Third-party libraries and open-source tools are allowed.
- Each team submits one project via a single pull request.
- Keep your submission self-contained within your team's folder.



## License

Unless stated otherwise in an individual submission, the contents of this repository are licensed under the [MIT License](LICENSE).

## Questions?

Open an [issue](../../issues) in this repository and we'll get back to you.
