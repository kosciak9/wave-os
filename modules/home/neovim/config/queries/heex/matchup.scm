; inherits: quote

(tag) @scope.tag
(component) @scope.component
(slot) @scope.slot

(start_tag
  (tag_name) @open.tag)

(end_tag
  (tag_name) @close.tag
  (#offset! @close.tag 0 -1 0 0))

(start_component
  (component_name) @open.component)

(end_component
  (component_name) @close.component
  (#offset! @close.component 0 -1 0 0))

(start_slot
  (slot_name) @open.slot)

(end_slot
  (slot_name) @close.slot
  (#offset! @close.slot 0 -1 0 0))

(self_closing_tag
  (tag_name) @open.selftag
  "/>" @close.selftag) @scope.selftag

(self_closing_component
  (component_name) @open.selfcomponent
  "/>" @close.selfcomponent) @scope.selfcomponent

(self_closing_slot
  (slot_name) @open.selfslot
  "/>" @close.selfslot) @scope.selfslot
