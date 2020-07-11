# voile
SHOO's scrap library for D language.

<!-- [![GitHub tag](https://img.shields.io/github/tag/shoo/voile.svg?maxAge=86400)](#) -->
[![master](https://github.com/shoo/voile/workflows/status/badge.svg)](https://github.com/shoo/voile/actions?query=workflow%3Astatus)
[![codecov](https://codecov.io/gh/shoo/voile/branch/master/graph/badge.svg)](https://codecov.io/gh/shoo/voile)

# Instlation and Build

Voile is a github project, hosted at https://github.com/shoo/voile
To get and build it:

```sh
git clone https://github.com/shoo/voile.git
cd voile
dub build
```

Add to dub
```sh
git clone https://github.com/shoo/voile.git
dub add-path voile
```

Or, add dependencies with path on dub.json/dub.sdl
```json
{
  "dependencies": {
    "voile": {"path": "../voile", "version": "*" }
  }
}
```

# License
public domain
