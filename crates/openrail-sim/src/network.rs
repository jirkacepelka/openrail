//! Route finding over the track network.

use std::cmp::Reverse;
use std::collections::{BTreeMap, BinaryHeap, VecDeque};

use crate::world::{NodeId, Track, TrackId};
use crate::Fixed;

/// Shortest path from `from` to `to` as the list of tracks to drive, plus
/// its length. Ties between equal-length paths are broken by node and
/// track id, so every machine picks the same route.
pub fn shortest_path(
    tracks: &BTreeMap<TrackId, Track>,
    from: NodeId,
    to: NodeId,
) -> Option<(VecDeque<TrackId>, Fixed)> {
    shortest_path_avoiding(tracks, from, to, &|_| true)
}

/// Like [`shortest_path`], using only tracks for which `usable` is true.
pub fn shortest_path_avoiding(
    tracks: &BTreeMap<TrackId, Track>,
    from: NodeId,
    to: NodeId,
    usable: &dyn Fn(TrackId) -> bool,
) -> Option<(VecDeque<TrackId>, Fixed)> {
    if from == to {
        return Some((VecDeque::new(), Fixed::ZERO));
    }
    let mut adjacent: BTreeMap<NodeId, Vec<(TrackId, NodeId, Fixed)>> = BTreeMap::new();
    for (&id, t) in tracks.iter().filter(|(&id, _)| usable(id)) {
        adjacent.entry(t.a).or_default().push((id, t.b, t.length));
        adjacent.entry(t.b).or_default().push((id, t.a, t.length));
    }

    let mut best: BTreeMap<NodeId, (Fixed, Option<(NodeId, TrackId)>)> = BTreeMap::new();
    let mut queue = BinaryHeap::new();
    best.insert(from, (Fixed::ZERO, None));
    queue.push(Reverse((Fixed::ZERO, from)));

    while let Some(Reverse((dist, node))) = queue.pop() {
        if node == to {
            break;
        }
        if best.get(&node).is_some_and(|&(d, _)| d < dist) {
            continue;
        }
        for &(track, next, len) in adjacent.get(&node).into_iter().flatten() {
            let candidate = dist + len;
            let better = match best.get(&next) {
                None => true,
                Some(&(d, _)) => candidate < d,
            };
            if better {
                best.insert(next, (candidate, Some((node, track))));
                queue.push(Reverse((candidate, next)));
            }
        }
    }

    let &(total, _) = best.get(&to)?;
    let mut path = VecDeque::new();
    let mut node = to;
    while let Some(&(_, Some((prev, track)))) = best.get(&node) {
        path.push_front(track);
        node = prev;
    }
    Some((path, total))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PlayerId;

    fn track(a: u32, b: u32, len: i32) -> Track {
        Track {
            a: NodeId(a),
            b: NodeId(b),
            length: Fixed::from_int(len),
            owner: PlayerId(0),
        }
    }

    #[test]
    fn picks_the_shorter_branch() {
        // 1 -10- 2 -10- 4 and 1 -5- 3 -5- 4
        let tracks = BTreeMap::from([
            (TrackId(10), track(1, 2, 10)),
            (TrackId(11), track(2, 4, 10)),
            (TrackId(12), track(1, 3, 5)),
            (TrackId(13), track(4, 3, 5)),
        ]);
        let (path, len) = shortest_path(&tracks, NodeId(1), NodeId(4)).unwrap();
        assert_eq!(path, [TrackId(12), TrackId(13)]);
        assert_eq!(len, Fixed::from_int(10));
    }

    #[test]
    fn unreachable_is_none() {
        let tracks = BTreeMap::from([(TrackId(10), track(1, 2, 10))]);
        assert!(shortest_path(&tracks, NodeId(1), NodeId(3)).is_none());
        assert!(shortest_path(&tracks, NodeId(2), NodeId(2))
            .unwrap()
            .0
            .is_empty());
    }
}
