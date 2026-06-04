# Unity Game Libs Nuget Creator

Creates nugets with stripped and publicized libraries for Unity game modding.

If the game gets updated, this package needs to get updated too.

`strip-assembiles.bat` does three things:

- Downloads full Unity engine and corlib reference assemblies for the game's Unity version from [unity.bepinex.dev/libraries](https://unity.bepinex.dev/libraries/) and [unity.bepinex.dev/corlibs](https://unity.bepinex.dev/corlibs/).
- Replaces any matching stripped game-shipped Unity/corlib assemblies with those full reference assemblies as temporary inputs, then hollows everything with [NStrip](https://github.com/BepInEx/NStrip).
- Runs a final Mono.Cecil-based hollowing pass over the generated package assemblies so method bodies missed by NStrip, such as default interface implementations, are removed too.
- Publicizes configured game assemblies. This makes all types, methods, properties and fields public, to make modding easier.

## Usage

### Nuget account

- Go to [nuget.org](https://nuget.org/).
- Either log in, or create a new account.
- [Create a new API key](https://www.nuget.org/account/apikeys) with permissions to push new packages.

### Prepare your repository

- [Create a new repository based on this template](https://github.com/Raicuparta/unity-libs-nuget/generate).
- Add a secret called `NUGET_KEY` to this repository. Give it the value of the API key you created earlier.
- Update the repository's name. This will be used as your Nuget ID, so it can't clash with another nuget package on [nuget.org](https://nuget.org/).
- Update the repository's description. This will be used as the nuget's description too.

### Generate the stripped libraries

- Make sure you start off with a clean version of the game files, with no extra/modified dlls.
- Make sure the .NET SDK is installed. It is used by the final hollowing pass.
- Drag the game's exe and drop it on `strip-assembiles.bat`.
- Dlls are stripped, publicized, and placed in `package\lib`.
- The script tries to derive the Unity version from `UnityPlayer.dll`.
- If version detection fails, or you want to force a version, run `strip-assembiles.bat "C:\Path\Game.exe" 2022.3.62`.
- To check the detected Unity version without downloading or regenerating DLLs, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\strip-assemblies.ps1 "C:\Path\Game.exe" -VersionOnly`.

### Updating the Nuget

- Edit the `.nuspec` file, make `<version>` match the game version where these assemblies come from.
- Push to the default branch.
- Updating the default branch will trigger a workflow that will pack the dlls and update the NuGet package.

### Publicized assemblies

By default, only `Assembly-CSharp.dll`, `Mouse.dll`, and `Mouse.PackedSprites.dll` are publicized. All other dlls are stripped only. To publicize other dlls, edit `strip-assemblies.ps1` and add the dll names to the `$ToPublicize` variable.

### Untouched assemblies

By default, every game assembly gets stripped. If there's any assembly you wish to keep in the package in its original state, add the dll names to the `$DontTouch` variable in `strip-assemblies.ps1`.
