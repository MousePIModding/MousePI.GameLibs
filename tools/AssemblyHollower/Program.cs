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
var failures = new List<string>();

foreach (var assemblyPath in assemblies)
{
    try
    {
        var changedMethods = HollowAssembly(assemblyPath, out var alreadyHollow, out var withoutBodies);
        alreadyHollowMethods += alreadyHollow;
        methodsWithoutBodies += withoutBodies;

        if (changedMethods > 0)
        {
            changedAssemblies++;
            hollowedMethods += changedMethods;
            Console.WriteLine($"Hollowed {changedMethods} remaining method bodies in {Path.GetFileName(assemblyPath)}");
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

static int HollowAssembly(string assemblyPath, out int alreadyHollowMethods, out int methodsWithoutBodies)
{
    alreadyHollowMethods = 0;
    methodsWithoutBodies = 0;

    var assemblyDirectory = Path.GetDirectoryName(assemblyPath) ?? ".";
    var resolver = new DefaultAssemblyResolver();
    resolver.AddSearchDirectory(assemblyDirectory);

    using var module = ModuleDefinition.ReadModule(assemblyPath, new ReaderParameters
    {
        AssemblyResolver = resolver,
        InMemory = true,
        ReadSymbols = false
    });

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

    if (changedMethods == 0)
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
