# media

Project screenshots referenced by the main [README](../README.md).

| File | Used for |
|---|---|
| `info_light.png` | Hero screenshot when GitHub is in light mode (and as the fallback) |
| `info_dark.png` | Hero screenshot when GitHub is in dark mode |

The main README uses a `<picture>` element with `prefers-color-scheme` media
queries, so GitHub picks the matching image automatically:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="media/info_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="media/info_light.png">
  <img src="media/info_light.png" alt="…" width="900">
</picture>
```

Keep the images reasonably sized (around 1600 px wide is plenty) so the
repository does not grow for no reason. The two current PNGs are 1920 × 1200
and about 9 MB each; re-encode them before adding more screenshots.
