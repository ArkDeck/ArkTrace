"""Current source-backed split-group relation. No legacy same-group fallback."""

def split_group_relation(parent, root, helper, parser):
    rows = (parent, root, helper, parser)
    if any(type(row) is not tuple or len(row) != 5 for row in rows):
        return False
    for row in rows:
        if any(type(x) is not int for x in row):
            return False
        if any(x <= 0 or x > 2147483647 for x in row[:3]):
            return False
        if row[3] <= 0 or row[3] > 18446744073709551615 or not 0 <= row[4] < 1000000:
            return False
    if len({row[0] for row in rows}) != 4:
        return False
    return (root[1] == parent[0] and helper[1] == root[0] and parser[1] == helper[0]
        and root[2] == root[0] and helper[2] == helper[0] and parser[2] == parser[0]
        and len({root[2], helper[2], parser[2]}) == 3)
