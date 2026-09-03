# README diagrams

- Hex's package README does not execute Mermaid. The root README uses SVG images hosted in this directory on the repository's `main` branch.
- Each `.mmd` file is the source for its adjacent `.svg` file. Update both files together.
- Render with Mermaid 10.2.3, the version used by the HexDocs configuration in `mix.exs`, using `theme: "default"` and `flowchart: {htmlLabels: false}`. Plain SVG text avoids HTML labels inside image elements.
- Set the SVG's explicit width and height from its viewBox dimensions and use a white background. Verify each SVG loads as an image, not only as an inline diagram.
- Push the assets before publishing documentation that references them. A local docs build cannot make the GitHub image URLs available.
