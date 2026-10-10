//! A persistent stack: a copy is one pointer, and copies share their frames,
//! so the highlighter and the maths scan keep their state at many places in
//! a text for no more than a pointer each, however deep it is.

use std::sync::Arc;

pub(crate) struct Stack<T>(Option<Arc<Frame<T>>>);

#[derive(Clone)]
struct Frame<T> {
    item: T,
    below: Stack<T>,
}

impl<T> Clone for Stack<T> {
    fn clone(&self) -> Self {
        Stack(self.0.clone())
    }
}

impl<T> Default for Stack<T> {
    fn default() -> Self {
        Stack(None)
    }
}

impl<T> Stack<T> {
    pub fn push(&mut self, item: T) {
        let below = std::mem::take(self);
        *self = Stack(Some(Arc::new(Frame { item, below })));
    }

    pub fn pop(&mut self) {
        if let Some(frame) = self.0.take() {
            *self = frame.below.clone();
        }
    }

    pub fn top(&self) -> Option<&T> {
        self.0.as_deref().map(|frame| &frame.item)
    }

    /// The top item, copied out of frames other stacks share.
    pub fn top_mut(&mut self) -> Option<&mut T>
    where
        T: Clone,
    {
        self.0.as_mut().map(|frame| &mut Arc::make_mut(frame).item)
    }

    fn frames(&self) -> impl Iterator<Item = &Frame<T>> {
        std::iter::successors(self.0.as_deref(), |frame| frame.below.0.as_deref())
    }

    /// From the top down.
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.frames().map(|frame| &frame.item)
    }

    /// Take off the innermost item `pick` takes (the outermost, given
    /// `outermost`) and all above it, handing it to `taken` first.
    pub fn pop_to(&mut self, outermost: bool, pick: impl Fn(&T) -> bool, taken: impl FnOnce(&T)) {
        let mut found = None;
        for frame in self.frames() {
            if pick(&frame.item) {
                found = Some(frame);
                if !outermost {
                    break;
                }
            }
        }
        if let Some(frame) = found {
            let below = frame.below.clone();
            taken(&frame.item);
            *self = below;
        }
    }
}

/// Unlinked a frame at a time: dropping a deep stack recursively would
/// overflow the thread's own.
impl<T> Drop for Stack<T> {
    fn drop(&mut self) {
        let mut next = self.0.take();
        while let Some(frame) = next {
            next = Arc::try_unwrap(frame)
                .ok()
                .and_then(|mut f| f.below.0.take());
        }
    }
}
