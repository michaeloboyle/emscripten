###
  A script to eliminate redundant variables common in Emscripted code.

  A variable is eliminateable if it matches a leaf of this condition tree:

  Single-def
    Uses only side-effect-free nodes
      Unused
        *
      Has at most MAX_USES uses
        No mutations to any dependencies between def and last use
          No global dependencies or no indirect accesses between def and use
            *

  TODO(max99x): Eliminate single-def undefined-initialized vars with no uses
                between declaration and definition.
###

# Imports.
uglify = require 'uglify-js'
fs = require 'fs'

# Maximum number of uses to consider a variable not worth eliminating.
MAX_USES = 3

# The UglifyJs code generator settings to use.
GEN_OPTIONS =
  ascii_only: true
  beautify: true
  indent_level: 2

# Node types which can be evaluated without side effects.
NODES_WITHOUT_SIDE_EFFECTS =
  name: true
  num: true
  string: true
  binary: true
  sub: true

# Nodes which may break control flow. Moving a variable beyond them may have
# side effects.
CONTROL_FLOW_NODES =
  return: true
  break: true
  continue: true
  new: true
  throw: true
  call: true
  label: true
  debugger: true

# Traverses a JavaScript syntax tree rooted at the given node calling the given
# callback for each node.
#   @arg node: The root of the AST.
#   @arg callback: The callback to call for each node. This will be called with
#     the node as the first argument and its type as the second. If false is
#     returned, the traversal is stopped. If a non-undefined value is returned,
#     it replaces the passed node in the tree.
#   @returns: If the root node was replaced, the new root node. If the traversal
#     was stopped, false. Otherwise undefined.
traverse = (node, callback) ->
  type = node[0]
  if typeof type == 'string'
    result = callback node, type
    if result? then return result

  for subnode, index in node
    if typeof subnode is 'object' and subnode?.length
      # NOTE: For-in nodes have unspecified var mutations. Skip them.
      if type == 'for-in' and subnode?[0] == 'var' then continue
      subresult = traverse subnode, callback
      if subresult is false
        return false
      else if subresult?
        node[index] = subresult
  return undefined

# A class for eliminating redundant variables from JavaScript. Give it an AST
# function/defun node and call run() to apply the optimization (in-place).
class Eliminator
  constructor: (func) ->
    # The statements of the function to analyze.
    @body = func[3]

    # Identifier stats. Each of these objects is indexed by the identifier name.
    # Whether the identifier is a local variable.
    @isLocal = {}
    # Whether the identifier is never modified after initialization.
    @isSingleDef = {}
    # How many times the identifier is used.
    @useCount = {}
    # Whether the initial value of a single-def identifier uses only nodes
    # evaluating which has no side effects.
    @usesOnlySimpleNodes = {}
    # Whether the identifier depends on any non-local name, perhaps indirectly.
    @dependsOnAGlobal = {}
    # Whether the dependencies of the single-def identifier may be mutated
    # within its live range.
    @depsMutatedInLiveRange = {}
    # Maps a given single-def variable to the AST expression of its initial value.
    @initialValue = {}
    # Maps identifiers to single-def variables which reference it in their
    # initial value.
    @dependsOn = {}

  # Runs the eliminator on a given function body updating the AST in-place.
  #   @returns: The number of variables eliminated, or undefined if skipped.
  run: ->
    # Our optimization does not account for closures.
    if @hasClosures @body then return undefined

    @calculateBasicVarStats()
    @analyzeInitialValues()
    @calculateTransitiveDependencies()
    @analyzeLiveRanges()

    toReplace = {}
    eliminated = 0
    for varName of @isSingleDef
      if @isEliminateable varName
        toReplace[varName] = @initialValue[varName]
        eliminated++

    @removeDeclarations toReplace
    @collapseValues toReplace
    @updateUses toReplace

    return eliminated

  # Determines if a function is Emscripten-generated.
  hasClosures: ->
    closureFound = false

    traverse @body, (node, type) ->
      if type in ['defun', 'function', 'with']
        closureFound = true
        return false
      return undefined

    return closureFound

  # Runs the basic variable scan pass. Fills the following member variables:
  #   isLocal
  #   isSingleDef
  #   useCount
  #   initialValue
  calculateBasicVarStats: ->
    traverse @body, (node, type) =>
      if type is 'var'
        for [varName, varValue] in node[1]
          @isLocal[varName] = true
          if not varValue? then varValue = ['name', 'undefined']
          @isSingleDef[varName] = not @isSingleDef.hasOwnProperty varName
          @initialValue[varName] = varValue
          @useCount[varName] = 0
      else if type is 'name'
        varName = node[1]
        if @useCount.hasOwnProperty varName then @useCount[varName]++
        else @isSingleDef[varName] = false
      else if type in ['assign', 'unary-prefix', 'unary-postfix']
        varName = node[2][1]
        if @isSingleDef[varName] then @isSingleDef[varName] = false
      return undefined
    return undefined

  # Analyzes the initial values of single-def variables. Requires basic variable
  # stats to have been calculated. Fills the following member variables:
  #   dependsOn
  #   dependsOnAGlobal
  #   usesOnlySimpleNodes
  analyzeInitialValues: ->
    for varName of @isSingleDef
      if not @isSingleDef[varName] then continue
      @usesOnlySimpleNodes[varName] = true
      traverse @initialValue[varName], (node, type) =>
        if type not of NODES_WITHOUT_SIDE_EFFECTS
          @usesOnlySimpleNodes[varName] = false
        else if type is 'name'
          reference = node[1]
          if reference != 'undefined'
            if not @dependsOn[reference]? then @dependsOn[reference] = {}
            if not @isLocal[reference] then @dependsOnAGlobal[varName] = true
            @dependsOn[reference][varName] = true
        return undefined
    return undefined

  # Updates the dependency graph (@dependsOn) to its transitive closure and 
  # synchronizes @dependsOnAGlobal to the new dependencies.
  calculateTransitiveDependencies: ->
    incomplete = true
    while incomplete
      incomplete = false
      for target, sources of @dependsOn
        for source of sources
          for source2 of @dependsOn[source]
            if not @dependsOn[target][source2]
              if not @isLocal[target] then @dependsOnAGlobal[source2] = true
              @dependsOn[target][source2] = true
              incomplete = true
    return undefined

  # Analyzes the live ranges of single-def variables. Requires dependencies to
  # have been calculated. Fills the following member variables:
  #   depsMutatedInLiveRange
  analyzeLiveRanges: ->
    isLive = {}

    # Checks if a given node may mutate any of the currently live variables.
    checkForMutations = (node, type) =>
      usedInThisStatement = {}
      if type in ['assign', 'call']
        traverse node.slice(2, 4), (node, type) =>
          if type is 'name' then usedInThisStatement[node[1]] = true
          return undefined

      if type in ['assign', 'unary-prefix', 'unary-postfix']
        if type is 'assign' or node[1] in ['--', '++']
          reference = node[2]
          while reference[0] != 'name'
            reference = reference[1]
          reference = reference[1]
          if @dependsOn[reference]?
            for varName of @dependsOn[reference]
              if isLive[varName]
                isLive[varName] = false

      if type of CONTROL_FLOW_NODES
        for varName of isLive
          if @dependsOnAGlobal[varName] or not usedInThisStatement[varName]
            isLive[varName] = false
      else if type is 'assign'
        for varName of isLive
          if @dependsOnAGlobal[varName] and not usedInThisStatement[varName]
            isLive[varName] = false
      else if type is 'name'
        reference = node[1]
        if @isSingleDef[reference]
          if not isLive[reference]
            @depsMutatedInLiveRange[reference] = true
      return undefined

    # Analyzes a block and all its children for variable ranges. Makes sure to
    # account for the worst case of possible mutations.
    analyzeBlock = (node, type) =>
      if type in ['switch', 'if', 'try', 'do', 'while', 'for', 'for-in']
        traverseChild = (child) ->
          if typeof child == 'object' and child?.length
            savedLive = {}
            for name of isLive then savedLive[name] = true
            traverse child, analyzeBlock
            for name of isLive
              if not isLive[name] then savedLive[name] = false
            isLive = savedLive
        if type is 'switch'
          traverseChild node[1]
          for child in node[2]
            traverseChild child
        else if type in ['if', 'try']
          for child in node
            traverseChild child
        else
          # Don't put anything from outside into the body of a loop.
          savedLive = isLive
          isLive = {}
          for child in node then traverseChild child
          for name of isLive
            if not isLive[name] then savedLive[name] = false
          isLive = savedLive
        return node
      else if type is 'var'
        for [varName, varValue] in node[1]
          if varValue? then traverse varValue, checkForMutations
          if @isSingleDef[varName]
            isLive[varName] = true
        return node
      else
        checkForMutations node, type
      return undefined

    traverse @body, analyzeBlock

    return undefined

  # Determines whether a given variable can be safely eliminated. Requires all
  # analysis passes to have been run.
  isEliminateable: (varName) ->
    if @isSingleDef[varName] and @usesOnlySimpleNodes[varName]
      if @useCount[varName] == 0
        return true
      else if @useCount[varName] <= MAX_USES
        return not @depsMutatedInLiveRange[varName]
    return false

  # Removes all var declarations for the specified variables.
  #   @arg toRemove: An object whose keys are the variable names to remove.
  removeDeclarations: (toRemove) ->
    traverse @body, (node, type) ->
      if type is 'var'
        intactVars = (i for i in node[1] when not toRemove.hasOwnProperty i[0])
        if intactVars.length
          node[1] = intactVars
          return node
        else
          return ['toplevel', []]
      return undefined
    return undefined

  # Updates all the values for the given variables to eliminate reference to any
  # of the other variables in the group.
  #   @arg values: A map from variable names to their values as AST expressions.
  collapseValues: (values) ->
    incomplete = true
    while incomplete
      incomplete = false
      for varName, varValue of values
        result = traverse varValue, (node, type) ->
          if type == 'name' and values.hasOwnProperty(node[1]) and node[1] != varName
            incomplete = true
            return values[node[1]]
          return undefined
        if result? then values[varName] = result
    return undefined

  # Replaces all uses of the specified variables with their respective
  # expressions.
  #   @arg replacements: A map from variable names to AST expressions.
  updateUses: (replacements) ->
    traverse @body, (node, type) ->
      if type is 'name' and replacements.hasOwnProperty node[1]
        return replacements[node[1]]
      return undefined
    return undefined


# The main entry point. Reads JavaScript from stdin, runs the eliminator on each
# function, then writes the optimized result to stdout.
main = ->
  # Get the parse tree.
  src = fs.readFileSync('/dev/stdin').toString()
  ast = uglify.parser.parse src

  # Run the eliminator on all functions.
  traverse ast, (node, type) ->
    if type in ['defun', 'function']
      process.stderr.write (node[1] || '(anonymous)') + '\n'
      eliminated = new Eliminator(node).run()
      if eliminated?
        process.stderr.write "  Eliminated #{eliminated} vars.\n"
      else
        process.stderr.write '  Skipped.\n'
    return undefined

  # Write out the optimized code.
  # NOTE: For large file, can't generate code for the whole file in a single
  #       call due to the v8 memory limit. Writing out root children instead.
  for node in ast[1]
    process.stdout.write uglify.uglify.gen_code node, GEN_OPTIONS
    process.stdout.write '\n'

  return undefined

main()
