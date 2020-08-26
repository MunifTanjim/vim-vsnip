let s:max_tabstop = 1000000
let s:Position = vital#vsnip#import('VS.LSP.Position')

"
" import.
"
function! vsnip#snippet#import() abort
  return s:Snippet
endfunction

let s:Snippet = {}

"
" new.
"
function! s:Snippet.new(position, text) abort
  let l:pos = s:Position.lsp_to_vim('%', a:position)
  let l:snippet = extend(deepcopy(s:Snippet), {
  \   'type': 'snippet',
  \   'position': a:position,
  \   'before_text': getline(l:pos[0])[0 : l:pos[1] - 2],
  \   'origin_table': {},
  \   'children': vsnip#snippet#node#create_from_ast(
  \     vsnip#snippet#parser#parse(a:text)
  \   )
  \ })
  call l:snippet.init()
  call l:snippet.sync()
  return l:snippet
endfunction

"
" init.
"
" NOTE: Must not use the node range in this method.
"
function s:Snippet.init() abort
  let l:fn = {}
  let l:fn.self = self
  let l:fn.origin_table = {}
  let l:fn.variable_placeholder = {}
  let l:fn.has_final_tabstop = v:false
  function! l:fn.traverse(context) abort
    if a:context.node.type ==# 'placeholder'
      " Mark placeholder as origin/derived.
      let a:context.node.origin = !has_key(self.origin_table, a:context.node.id)
      if a:context.node.origin
        let self.origin_table[a:context.node.id] = a:context.node
      else
        let a:context.node.children = [vsnip#snippet#node#create_text('')]
      endif

      " Mark as having final tabstop
      if a:context.node.is_final
        let self.has_final_tabstop = v:true
      endif
    elseif a:context.node.type ==# 'variable'
      " TODO refactor
      " variable placeholder
      if a:context.node.unknown
        let a:context.node.type = 'placeholder'
        let a:context.node.choice = []

        if !has_key(self.variable_placeholder, a:context.node.name)
          let self.variable_placeholder[a:context.node.name] = s:max_tabstop - (len(self.variable_placeholder) + 1)
          let a:context.node.id = self.variable_placeholder[a:context.node.name]
          let a:context.node.origin = v:true
          let a:context.node.children = empty(a:context.node.children) ? [vsnip#snippet#node#create_text(a:context.node.name)] : a:context.node.children
          let self.origin_table[a:context.node.id] =  a:context.node
        else
          let a:context.node.id = self.variable_placeholder[a:context.node.name]
          let a:context.node.origin = v:false
        let a:context.node.children = [vsnip#snippet#node#create_text('')]
        endif
      endif
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  " Store origin_table
  let self.origin_table = l:fn.origin_table

  " Append ${MAX_TABSTOP} for the end of snippet.
  if !l:fn.has_final_tabstop
    let l:final_placeholder = vsnip#snippet#node#create_from_ast({
    \   'type': 'placeholder',
    \   'id': 0,
    \ })
    let self.children += [l:final_placeholder]
    let self.origin_table[l:final_placeholder.id] = l:final_placeholder
  endif
endfunction

"
" follow.
"
function! s:Snippet.follow(current_tabstop, diff) abort
  let l:range = self.range()
  let l:in_range = v:true
  let l:in_range = l:in_range && (l:range.start.line < a:diff.range.start.line || l:range.start.line == a:diff.range.start.line && l:range.start.character <= a:diff.range.start.character)
  let l:in_range = l:in_range && (l:range.end.line > a:diff.range.start.line || l:range.end.line == a:diff.range.end.line && l:range.end.character >= a:diff.range.end.character)
  if !l:in_range
    return v:false
  endif

  let a:diff.range = [
  \   self.position_to_offset(a:diff.range.start),
  \   self.position_to_offset(a:diff.range.end),
  \ ]

  let l:fn = {}
  let l:fn.current_tabstop = a:current_tabstop
  let l:fn.diff = a:diff
  let l:fn.context = v:null
  function! l:fn.traverse(context) abort
    " diff:     s-------e
    " text:   1-----------2
    " expect:       ^
    if a:context.range[0] <= self.diff.range[0] && self.diff.range[1] <= a:context.range[1]
      let l:should_update = v:false
      let l:should_update = l:should_update || empty(self.context)
      let l:should_update = l:should_update || a:context.node.type ==# 'placeholder'
      let l:should_update = l:should_update || self.context.depth > a:context.depth
      if l:should_update
        let self.context = a:context
      endif
      " Stop traversing when acceptable node is current tabstop.
      return self.context.node.type ==# 'placeholder' && self.context.node.id == self.current_tabstop && self.context.node.origin
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  let l:context = l:fn.context
  if empty(l:context)
    return v:false
  endif

  " Create patched new text.
  let l:start = a:diff.range[0] - l:context.range[0]
  let l:end = a:diff.range[1] - l:context.range[0]
  let l:new_text = ''
  let l:new_text .= strcharpart(l:context.text, 0, l:start)
  let l:new_text .= a:diff.text
  let l:new_text .= strcharpart(l:context.text, l:end, l:context.length - l:end)

  " Apply patched new text.
  if l:context.node.type ==# 'text'
    let l:context.node.value = l:new_text
  else
    let l:context.node.children = [vsnip#snippet#node#create_text(l:new_text)]
  endif

  " Convert to text node when edited node is derived node.
  let l:folding_targets = l:context.parents + [l:context.node]
  if len(l:folding_targets) > 1
    for l:i in range(1, len(l:folding_targets) - 1)
      let l:parent = l:folding_targets[l:i - 1]
      let l:node = l:folding_targets[l:i]
      if !get(l:node, 'origin', v:true) || l:node.type ==# 'variable'
        let l:index = index(l:parent.children, l:node)
        call remove(l:parent.children, l:index)
        call insert(l:parent.children, vsnip#snippet#node#create_text(l:node.text()), l:index)
        break
      endif
    endfor
  endif

  return v:true
endfunction

"
" sync.
"
function! s:Snippet.sync() abort
  let l:fn = {}
  let l:fn.contexts = []
  function! l:fn.traverse(context) abort
    let l:is_target = v:false
    let l:is_target = l:is_target || (a:context.node.type ==# 'placeholder' && !a:context.node.origin)
    let l:is_target = l:is_target || (a:context.node.type ==# 'variable')
    if l:is_target
      call add(self.contexts, a:context)
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  " Create text_edits.
  let l:text_edits = []
  for l:context in l:fn.contexts
    let l:resolved = l:context.node.evaluate(l:context)
    if l:resolved isnot# v:null && l:context.node.text() !=# l:resolved
      call add(l:text_edits, {
      \   'node': l:context.node,
      \   'range': {
      \     'start': self.offset_to_position(l:context.range[0]),
      \     'end': self.offset_to_position(l:context.range[1]),
      \   },
      \   'newText': l:resolved,
      \ })
    endif
  endfor

  " Sync placeholder text after created text_edits (the reason is to avoid using a modified range).
  for l:text_edit in l:text_edits
    call l:text_edit.node.resolve(l:text_edit.newText)
  endfor

  return l:text_edits
endfunction

"
" range.
"
function! s:Snippet.range() abort
  return {
  \   'start': self.offset_to_position(0),
  \   'end': self.offset_to_position(strchars(self.text()))
  \ }
endfunction

"
" text.
"
function! s:Snippet.text() abort
  return join(map(copy(self.children), 'v:val.text()'), '')
endfunction

"
" get_placeholder_nodes
"
function! s:Snippet.get_placeholder_nodes() abort
  let l:fn =  {}
  let l:fn.nodes = []
  function! l:fn.traverse(context) abort
    if a:context.node.type ==# 'placeholder'
      call add(self.nodes, a:context.node)
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  return sort(l:fn.nodes, { a, b -> a.id - b.id })
endfunction

"
" get_next_jump_point.
"
function! s:Snippet.get_next_jump_point(current_tabstop) abort
  let l:fn = {}
  let l:fn.current_tabstop = a:current_tabstop
  let l:fn.context = v:null
  function! l:fn.traverse(context) abort
    if a:context.node.type ==# 'placeholder' && self.current_tabstop < a:context.node.id
      if !empty(self.context) && self.context.node.id <= a:context.node.id
        return v:false
      endif

      let self.context = copy(a:context)
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  let l:context = l:fn.context
  if empty(l:context)
    return {}
  endif

  return {
  \   'placeholder': l:context.node,
  \   'range': {
  \     'start': self.offset_to_position(l:context.range[0]),
  \     'end': self.offset_to_position(l:context.range[1])
  \   }
  \ }
endfunction

"
" get_prev_jump_point.
"
function! s:Snippet.get_prev_jump_point(current_tabstop) abort
  let l:fn = {}
  let l:fn.current_tabstop = a:current_tabstop
  let l:fn.context = v:null
  function! l:fn.traverse(context) abort
    if a:context.node.type ==# 'placeholder' && self.current_tabstop > a:context.node.id
      if !empty(self.context) && self.context.node.id >= a:context.node.id
        return v:false
      endif
      let self.context = copy(a:context)
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  let l:context = l:fn.context
  if empty(l:context)
    return {}
  endif

  return {
  \   'placeholder': l:context.node,
  \   'range': {
  \     'start': self.offset_to_position(l:context.range[0]),
  \     'end': self.offset_to_position(l:context.range[1])
  \   }
  \ }
endfunction

"
" normalize
"
" - merge adjacent text-nodes
"
function! s:Snippet.normalize() abort
  let l:fn = {}
  let l:fn.prev_context = v:null
  function! l:fn.traverse(context) abort
    if !empty(self.prev_context)
      if self.prev_context.node.type ==# 'text' && a:context.node.type ==# 'text' && self.prev_context.parent is# a:context.parent
        let a:context.node.value = self.prev_context.node.value . a:context.node.value
        call remove(self.prev_context.parent.children, index(self.prev_context.parent.children, self.prev_context.node))
      endif
    endif
    let self.prev_context = copy(a:context)
  endfunction
  call self.traverse(self, l:fn.traverse)
endfunction

"
" insert_node
"
function! s:Snippet.insert_node(position, nodes_to_insert) abort
  let l:offset = self.position_to_offset(a:position)

  " Search target node for inserting nodes.
  let l:fn = {}
  let l:fn.offset = l:offset
  let l:fn.context = v:null
  function! l:fn.traverse(context) abort
    if a:context.range[0] <= self.offset && self.offset <= a:context.range[1] && a:context.node.type ==# 'text'
      " prefer more deeper node.
      if empty(self.context) || self.context.depth <= a:context.depth
        let self.context = copy(a:context)
      endif
    endif
  endfunction
  call self.traverse(self, l:fn.traverse)

  " This condition is unexpected normally
  let l:context = l:fn.context
  if empty(l:context)
    return
  endif

  " Remove target text node
  let l:index = index(l:context.parent.children, l:context.node)
  call remove(l:context.parent.children, l:index)

  " Should insert into existing text node when position is middle of node
  let l:nodes_to_insert = reverse(a:nodes_to_insert)
  if l:context.node.value !=# ''
    let l:off = l:offset - l:context.range[0]
    let l:before = vsnip#snippet#node#create_text(strcharpart(l:context.node.value, 0, l:off))
    let l:after = vsnip#snippet#node#create_text(strcharpart(l:context.node.value, l:off, strchars(l:context.node.value) - l:off))
    let l:nodes_to_insert = [l:after] + l:nodes_to_insert + [l:before]
  endif

  " Insert nodes.
  for l:node in l:nodes_to_insert
    call insert(l:context.parent.children, l:node, l:index)
  endfor

  call self.normalize()
  call self.init()
endfunction

"
" offset_to_position.
"
" @param offset 0-based index for snippet text.
" @return position buffer position
"
function! s:Snippet.offset_to_position(offset) abort
  let l:lines = split(strcharpart(self.text(), 0, a:offset), "\n", v:true)
  return {
  \   'line': self.position.line + len(l:lines) - 1,
  \   'character': strchars(l:lines[-1]) + (len(l:lines) == 1 ? self.position.character : 0),
  \ }
endfunction

"
" position_to_offset.
"
" @param position buffer position
" @return 0-based index for snippet text.
"
function! s:Snippet.position_to_offset(position) abort
  let l:line = a:position.line - self.position.line
  let l:char = a:position.character - (l:line == 0 ? self.position.character : 0)
  let l:lines = split(self.text(), "\n", v:true)[0 : l:line]
  let l:lines[-1] = strcharpart(l:lines[-1], 0, l:char)
  return strchars(join(l:lines, "\n"))
endfunction

"
" traverse.
"
function! s:Snippet.traverse(node, callback) abort
  let l:state = {
  \   'offset': 0,
  \   'before_text': self.before_text,
  \   'origin_table': self.origin_table,
  \ }
  let l:context = {
  \   'depth': 0,
  \   'parent': v:null,
  \   'parents': [],
  \ }
  call s:traverse(a:node, a:callback, l:state, l:context)
endfunction
function! s:traverse(node, callback, state, context) abort
  let l:text = ''
  let l:length = 0
  if a:node.type !=# 'snippet'
    let l:text = a:node.text()
    let l:length = strchars(l:text)
    if a:callback({
    \   'node': a:node,
    \   'text': l:text,
    \   'length': l:length,
    \   'parent': a:context.parent,
    \   'parents': a:context.parents,
    \   'depth': a:context.depth,
    \   'offset': a:state.offset,
    \   'before_text': a:state.before_text,
    \   'origin_table': a:state.origin_table,
    \   'range': [a:state.offset, a:state.offset + l:length],
    \ })
      return v:true
    endif
  endif

  if len(a:node.children) > 0
    let l:next_context = {
      \   'parent': a:node,
      \   'parents': a:context.parents + [a:node],
      \   'depth': len(a:context.parents) + 1,
      \ }
    for l:child in copy(a:node.children)
      if s:traverse(l:child, a:callback, a:state, l:next_context)
        return v:true
      endif
    endfor
  else
    let a:state.before_text .= l:text
    let a:state.offset += l:length
  endif
endfunction

"
" debug
"
function! s:Snippet.debug() abort
  echomsg 'snippet.text()'
  for l:line in split(self.text(), "\n", v:true)
    echomsg string(l:line)
  endfor
  echomsg '-----'

  let l:fn = {}
  function! l:fn.traverse(context) abort
    echomsg repeat('    ', a:context.depth - 1) . a:context.node.to_string()
  endfunction
  call self.traverse(self, l:fn.traverse)
  echomsg ' '
endfunction
