{EditorView, ScrollView, $} = require 'atom'
{Emitter} = require 'emissary'
Debug = require 'prolix'

module.exports =
class MinimapEditorView extends ScrollView
  Emitter.includeInto(this)
  Debug('minimap').includeInto(this)

  @content: ->
    @div class: 'minimap-editor editor editor-colors', =>
      @tag 'canvas', {
        outlet: 'lineCanvas'
        class: 'minimap-canvas'
        id: 'line-canvas'
      }

  frameRequested: false

  constructor: ->
    super
    @pendingChanges = []
    @context = @lineCanvas[0].getContext('2d')
    @tokenColorCache = {}

    @offscreenCanvas = document.createElement('canvas')
    @offscreenCtxt = @offscreenCanvas.getContext('2d')

  initialize: ->
    @lineOverdraw = atom.config.get('minimap.lineOverdraw')

    atom.config.observe 'minimap.lineOverdraw', =>
      @lineOverdraw = atom.config.get('minimap.lineOverdraw')

  pixelPositionForScreenPosition: (position) ->
    {row, column} = @buffer.constructor.Point.fromObject(position)
    actualRow = Math.floor(row)

    {top: row * @getLineHeight(), left: column}

  destroy: ->
    @unsubscribe()
    @editorView = null

  setEditorView: (@editorView) ->
    @editor = @editorView.getModel()
    @buffer = @editorView.getEditor().getBuffer()
    @displayBuffer = @editor.displayBuffer

    @subscribe @editor, 'screen-lines-changed.minimap', (changes) =>
      #@pendingChanges.push changes
      @requestUpdate()

    @subscribe @editor, 'contents-modified.minimap', =>
      @requestUpdate()

    @subscribe @displayBuffer, 'tokenized.minimap', =>
      @requestUpdate()

  requestUpdate: ->
    return if @frameRequested
    @frameRequested = true

    setImmediate =>
      @startBench()
      @update()
      @endBench('minimap update')
      @frameRequested = false

  forceUpdate: ->
    @tokenColorCache = {}
    @offscreenFirstRow = null
    @offscreenLastRow = null
    @requestUpdate()

  scrollTop: (scrollTop, options={}) ->
    return @cachedScrollTop or 0 unless scrollTop?
    return if scrollTop is @cachedScrollTop

    @cachedScrollTop = scrollTop
    @requestUpdate()


  getMinimapHeight: -> @getLinesCount() * @getLineHeight()
  getLineHeight: -> 2
  getLinesCount: -> @editorView.getEditor().getScreenLineCount()

  getMinimapScreenHeight: -> @minimapView.height() #/ @minimapView.scaleY
  getMinimapHeightInLines: -> Math.ceil(@getMinimapScreenHeight() / @getLineHeight())

  getFirstVisibleScreenRow: ->
    screenRow = Math.floor(@scrollTop() / @getLineHeight())
    screenRow = 0 if isNaN(screenRow)
    screenRow

  getLastVisibleScreenRow: ->
    calculatedRow = Math.ceil((@scrollTop() + @getMinimapScreenHeight()) / @getLineHeight()) - 1
    screenRow = Math.max(0, Math.min(@editor.getScreenLineCount() - 1, calculatedRow))
    screenRow = 0 if isNaN(screenRow)
    screenRow


  retrieveTokenColorFromDom: (token)->
    # This function insert a dummy token element in the DOM compute its style,
    # return its color property, and remove the element from the DOM.
    # This is quite an expensive operation so results are cached in getTokenColor.
    # Note: it's probably not the best way to do that, but that's the simpler approach I found.
    dummyNode = @editorView.find('#minimap-dummy-node')
    if dummyNode[0]?
      root = dummyNode[0]
    else
      root = document.createElement('span')
      root.style.visibility = 'hidden'
      root.id = 'minimap-dummy-node'
      @editorView.append(root)

    parent = root
    for scope in token.scopes
      node = document.createElement('span')
      # css class is the token scope without the dots,
      # see pushScope @ atom/atom/src/lines-component.coffee
      node.className = scope.replace(/\.+/g, ' ')
      if parent
        parent.appendChild(node)
      parent = node

    color = getComputedStyle(parent).getPropertyValue('color')
    root.innerHTML = ''
    color

  getTokenColor: (token)->
    #Retrieve color from cache if available
    flatScopes = token.scopes.join()
    if flatScopes not of @tokenColorCache
      color = @retrieveTokenColorFromDom(token)
      @tokenColorCache[flatScopes] = color
    @tokenColorCache[flatScopes]

  drawLines: (firstRow, lastRow, offsetRow, context) ->
    lines = @editor.linesForScreenRows(firstRow, lastRow)
    context.lineWidth = 1
    lineHeight = @getLineHeight()

    if @minimapView.displayCodeHighlights
      for line, row in lines
        x = 0
        y = offsetRow + row
        for token in line.tokens
          w = token.screenDelta
          if not token.isOnlyWhitespace()
            color = @getTokenColor(token)
            context.beginPath()
            context.strokeStyle = color
            context.moveTo(x, y*lineHeight)
            context.lineTo(x+w, y*lineHeight)
            context.stroke()
          x += w
    else
      context.strokeStyle = "#C0C0C0"
      context.beginPath()
      for line, row in lines
        w = line.text.length
        y = offsetRow + row
        if w > 0
          w0 = line.indentLevel * 2
          context.moveTo(w0, y*lineHeight+0.5)
          context.lineTo(w, y*lineHeight+0.5)
      context.stroke()

  update: =>
    return unless @editorView?
    return unless @displayBuffer.tokenizedBuffer.fullyTokenized

    #reset canvas virtual width/height
    @lineCanvas[0].width = @lineCanvas[0].offsetWidth
    @lineCanvas[0].height = @lineCanvas[0].offsetHeight

    firstRow = @getFirstVisibleScreenRow()
    lastRow = @getLastVisibleScreenRow()

    if @offscreenFirstRow?
      @context.drawImage(@offscreenCanvas, 0, (@offscreenFirstRow-firstRow) * 2)
      if firstRow < @offscreenFirstRow
        @drawLines(firstRow, @offscreenFirstRow, 0, @context)
      if lastRow > @offscreenLastRow
        @drawLines(@offscreenLastRow, lastRow, @offscreenLastRow-firstRow, @context)
    else
      @drawLines(firstRow, lastRow, 0, @context)


    # copy displayed canvas to offscreen canvas
    @offscreenCanvas.width = @lineCanvas[0].width
    @offscreenCanvas.height = @lineCanvas[0].height
    @offscreenCtxt.drawImage(@lineCanvas[0], 0, 0)
    @offscreenFirstRow = firstRow
    @offscreenLastRow = lastRow

    @emit 'minimap:updated'

  getClientRect: ->
    canvas = @lineCanvas[0]
    {
      width: canvas.scrollWidth,
      height: @getMinimapHeight()
    }
