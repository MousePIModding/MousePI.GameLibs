using Mono.Cecil;
using Mono.Cecil.Cil;

if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: AssemblyHollower <assembly-or-directory> [assembly-or-directory...]");
    return 1;
}

var assemblies = args
    .SelectMany(ExpandAssemblyPaths)
    .Distinct(StringComparer.OrdinalIgnoreCase)
    .OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase)
    .ToArray();

if (assemblies.Length == 0)
{
    Console.Error.WriteLine("No assemblies found.");
    return 1;
}

var changedAssemblies = 0;
var hollowedMethods = 0;
var alreadyHollowMethods = 0;
var methodsWithoutBodies = 0;
var removedNetstandardReferences = 0;
var failures = new List<string>();

foreach (var assemblyPath in assemblies)
{
    try
    {
        var changedMethods = HollowAssembly(
            assemblyPath,
            out var alreadyHollow,
            out var withoutBodies,
            out var removedNetstandard);

        alreadyHollowMethods += alreadyHollow;
        methodsWithoutBodies += withoutBodies;
        removedNetstandardReferences += removedNetstandard;

        if (changedMethods > 0 || removedNetstandard > 0)
        {
            changedAssemblies++;
            hollowedMethods += changedMethods;
            Console.WriteLine(
                $"Updated {Path.GetFileName(assemblyPath)}: hollowed {changedMethods} remaining method bodies, removed {removedNetstandard} netstandard references");
        }
    }
    catch (Exception ex)
    {
        failures.Add($"{assemblyPath}: {ex.GetType().Name}: {ex.Message}");
    }
}

Console.WriteLine($"Assemblies checked: {assemblies.Length}");
Console.WriteLine($"Assemblies changed: {changedAssemblies}");
Console.WriteLine($"Remaining method bodies hollowed: {hollowedMethods}");
Console.WriteLine($"Already hollow method bodies: {alreadyHollowMethods}");
Console.WriteLine($"Methods without bodies: {methodsWithoutBodies}");
Console.WriteLine($"netstandard references removed: {removedNetstandardReferences}");

if (failures.Count == 0)
{
    return 0;
}

foreach (var failure in failures)
{
    Console.Error.WriteLine(failure);
}

return 1;

static IEnumerable<string> ExpandAssemblyPaths(string path)
{
    if (Directory.Exists(path))
    {
        return Directory.EnumerateFiles(path, "*.dll", SearchOption.TopDirectoryOnly);
    }

    if (File.Exists(path) && path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
    {
        return new[] { path };
    }

    throw new FileNotFoundException($"Assembly or directory was not found: {path}", path);
}

static int HollowAssembly(
    string assemblyPath,
    out int alreadyHollowMethods,
    out int methodsWithoutBodies,
    out int removedNetstandardReferences)
{
    alreadyHollowMethods = 0;
    methodsWithoutBodies = 0;
    removedNetstandardReferences = 0;

    var assemblyDirectory = Path.GetDirectoryName(assemblyPath) ?? ".";
    var resolver = new DefaultAssemblyResolver();
    resolver.AddSearchDirectory(assemblyDirectory);

    using var module = ModuleDefinition.ReadModule(assemblyPath, new ReaderParameters
    {
        AssemblyResolver = resolver,
        InMemory = true,
        ReadSymbols = false
    });

    removedNetstandardReferences = RetargetNetstandardReferences(module);

    var changedMethods = 0;
    foreach (var method in module.Types.SelectMany(AllTypes).SelectMany(type => type.Methods))
    {
        if (!method.HasBody)
        {
            methodsWithoutBodies++;
            continue;
        }

        if (IsThrowNullBody(method))
        {
            alreadyHollowMethods++;
            continue;
        }

        ReplaceWithThrowNull(method);
        changedMethods++;
    }

    if (changedMethods == 0 && removedNetstandardReferences == 0)
    {
        return 0;
    }

    var tempPath = Path.Combine(
        assemblyDirectory,
        $"{Path.GetFileNameWithoutExtension(assemblyPath)}.{Guid.NewGuid():N}.tmp.dll");

    module.Write(tempPath);
    File.Move(tempPath, assemblyPath, overwrite: true);

    return changedMethods;
}

static int RetargetNetstandardReferences(ModuleDefinition module)
{
    var netstandardReferences = module.AssemblyReferences
        .Where(reference => reference.Name == "netstandard")
        .ToArray();

    if (netstandardReferences.Length == 0)
    {
        return 0;
    }

    var mscorlibReference = module.AssemblyReferences
        .FirstOrDefault(reference => reference.Name == "mscorlib");

    if (mscorlibReference is null)
    {
        mscorlibReference = new AssemblyNameReference("mscorlib", new Version(4, 0, 0, 0))
        {
            PublicKeyToken = Convert.FromHexString("B77A5C561934E089")
        };

        module.AssemblyReferences.Add(mscorlibReference);
    }

    foreach (var typeReference in module.GetTypeReferences())
    {
        if (typeReference.Scope is AssemblyNameReference assemblyReference
            && assemblyReference.Name == "netstandard")
        {
            typeReference.Scope = mscorlibReference;
        }
    }

    foreach (var reference in netstandardReferences)
    {
        module.AssemblyReferences.Remove(reference);
    }

    return netstandardReferences.Length;
}

static bool IsThrowNullBody(MethodDefinition method)
{
    var instructions = method.Body.Instructions
        .Where(instruction => instruction.OpCode.Code != Code.Nop)
        .ToArray();

    return instructions.Length == 2
        && instructions[0].OpCode.Code == Code.Ldnull
        && instructions[1].OpCode.Code == Code.Throw
        && method.Body.ExceptionHandlers.Count == 0;
}

static void ReplaceWithThrowNull(MethodDefinition method)
{
    var body = method.Body;
    body.Instructions.Clear();
    body.ExceptionHandlers.Clear();
    body.Variables.Clear();
    body.InitLocals = false;
    body.MaxStackSize = 1;
    body.Instructions.Add(Instruction.Create(OpCodes.Ldnull));
    body.Instructions.Add(Instruction.Create(OpCodes.Throw));
}

static IEnumerable<TypeDefinition> AllTypes(TypeDefinition type)
{
    yield return type;

    foreach (var nestedType in type.NestedTypes)
    {
        foreach (var childType in AllTypes(nestedType))
        {
            yield return childType;
        }
    }
}
