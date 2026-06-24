// target elements with the "draggable" class
interact('.draggable')
  .draggable({
   // Disabled inertia, because it restricted area where to drag card,
   //   and returned card to wrong position.
   // enable inertial throwing
   //inertia: true, // This is default. Trying to disable it.
   inertia: false,
   // keep the element within the area of it's parent. // This is default. Trying to disable it.
   /*
   modifiers: [
     interact.modifiers.restrictRect({
       restriction: 'parent',
         endOnly: true
     })
     ],
   */
   // enable autoScroll
   autoScroll: true,
     listeners: {
       // call this function on every dragmove event
       move: dragMoveListener,
       // call this function on every dragend event
       end (event) {
         var textEl = event.target.querySelector('p')
           textEl && (textEl.textContent =
            'moved ' +  (Math.sqrt(Math.pow(event.pageX - event.x0, 2) +
                         Math.pow(event.pageY - event.y0, 2) | 0))
                .toFixed(0) + 'px from ' +
                'x' + event.x0.toFixed(0) + '=>' + event.pageX.toFixed(0) +
                ', y' + event.y0.toFixed(0) + '=>' + event.pageY.toFixed(0));
         }
       }
     })
  function dragMoveListener (event) {
    var target = event.target
    // keep the dragged position in the data-x/data-y attributes
    var x = (parseFloat(target.getAttribute('data-x')) || 0) + event.dx
    var y = (parseFloat(target.getAttribute('data-y')) || 0) + event.dy
    // translate the element
    target.style.transform = 'translate(' + x + 'px, ' + y + 'px)'
    // update the posiion attributes
    target.setAttribute('data-x', x)
    target.setAttribute('data-y', y)
  }
  // this function is used later in the resizing and gesture demos
  window.dragMoveListener = dragMoveListener
