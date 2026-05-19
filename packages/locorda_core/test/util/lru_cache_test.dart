import 'package:locorda_core/src/util/lru_cache.dart';
import 'package:test/test.dart';

void main() {
  group('LRUCache', () {
    group('Basic Operations', () {
      test('should store and retrieve values', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;
        cache['key2'] = 2;

        expect(cache['key1'], 1);
        expect(cache['key2'], 2);
      });

      test('should return null for non-existent keys', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        expect(cache['nonexistent'], isNull);
      });

      test('should support containsKey check', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;

        expect(cache.containsKey('key1'), isTrue);
        expect(cache.containsKey('key2'), isFalse);
      });

      test('should remove entries', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;
        cache['key2'] = 2;

        final removed = cache.remove('key1');

        expect(removed, 1);
        expect(cache.containsKey('key1'), isFalse);
        expect(cache['key1'], isNull);
      });

      test('should return null when removing non-existent key', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        expect(cache.remove('nonexistent'), isNull);
      });

      test('should clear all entries', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;
        cache['key2'] = 2;
        cache['key3'] = 3;

        cache.clear();

        expect(cache.containsKey('key1'), isFalse);
        expect(cache.containsKey('key2'), isFalse);
        expect(cache.containsKey('key3'), isFalse);
      });
    });

    group('LRU Eviction', () {
      test('should evict oldest entry when cache is full', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;
        cache['key2'] = 2;
        cache['key3'] = 3;

        // Cache is full, adding new entry should evict key1
        cache['key4'] = 4;

        expect(cache.containsKey('key1'), isFalse);
        expect(cache.containsKey('key2'), isTrue);
        expect(cache.containsKey('key3'), isTrue);
        expect(cache.containsKey('key4'), isTrue);
      });

      test('should evict least recently used entry', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;
        cache['key2'] = 2;
        cache['key3'] = 3;

        // Access key1 (moves it to end, making key2 the oldest)
        final _ = cache['key1'];

        // Add new entry, should evict key2 (now the oldest)
        cache['key4'] = 4;

        expect(cache.containsKey('key1'), isTrue); // Recently accessed
        expect(cache.containsKey('key2'), isFalse); // Evicted (oldest)
        expect(cache.containsKey('key3'), isTrue);
        expect(cache.containsKey('key4'), isTrue);
      });

      test('should handle multiple accesses correctly', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1; // [key1]
        cache['key2'] = 2; // [key1, key2]
        cache['key3'] = 3; // [key1, key2, key3]

        // Access key1 multiple times
        final _ = cache['key1']; // [key2, key3, key1]
        cache['key1']; // [key2, key3, key1]

        // Add new entry, should evict key2
        cache['key4'] = 4; // [key3, key1, key4]

        expect(cache.containsKey('key1'), isTrue);
        expect(cache.containsKey('key2'), isFalse); // Evicted
        expect(cache.containsKey('key3'), isTrue);
        expect(cache.containsKey('key4'), isTrue);
      });

      test('should update existing entry without eviction', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['key1'] = 1;
        cache['key2'] = 2;
        cache['key3'] = 3;

        // Update key1 (should not trigger eviction)
        cache['key1'] = 10;

        expect(cache['key1'], 10);
        expect(cache.containsKey('key2'), isTrue);
        expect(cache.containsKey('key3'), isTrue);
      });
    });

    group('LRU Order Verification', () {
      test('should maintain correct LRU order with mixed operations', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        cache['a'] = 1; // [a]
        cache['b'] = 2; // [a, b]
        cache['c'] = 3; // [a, b, c]

        // Access 'b' (moves to end)
        final _ = cache['b']; // [a, c, b]

        // Add new entry, should evict 'a'
        cache['d'] = 4; // [c, b, d]

        expect(cache.containsKey('a'), isFalse); // Evicted
        expect(cache.containsKey('b'), isTrue);
        expect(cache.containsKey('c'), isTrue);
        expect(cache.containsKey('d'), isTrue);

        // Access 'c'
        cache['c']; // [b, d, c]

        // Add new entry, should evict 'b'
        cache['e'] = 5; // [d, c, e]

        expect(cache.containsKey('b'), isFalse); // Evicted
        expect(cache.containsKey('c'), isTrue);
        expect(cache.containsKey('d'), isTrue);
        expect(cache.containsKey('e'), isTrue);
      });

      test('should handle alternating access pattern', () {
        final cache = LRUCache<String, int>(maxCacheSize: 2);

        cache['key1'] = 1; // [key1]
        cache['key2'] = 2; // [key1, key2]

        // Alternating access keeps both in cache
        for (var i = 0; i < 10; i++) {
          final _ = cache['key1']; // [key2, key1]
          cache['key2']; // [key1, key2]
        }

        expect(cache.containsKey('key1'), isTrue);
        expect(cache.containsKey('key2'), isTrue);
      });
    });

    group('Edge Cases', () {
      test('should handle cache size of 1', () {
        final cache = LRUCache<String, int>(maxCacheSize: 1);

        cache['key1'] = 1;
        expect(cache['key1'], 1);

        cache['key2'] = 2;
        expect(cache.containsKey('key1'), isFalse);
        expect(cache['key2'], 2);
      });

      test('should handle empty cache', () {
        final cache = LRUCache<String, int>(maxCacheSize: 3);

        expect(cache['key1'], isNull);
        expect(cache.containsKey('key1'), isFalse);
      });

      test('should handle null values', () {
        final cache = LRUCache<String, int?>(maxCacheSize: 3);

        cache['key1'] = null;

        expect(cache.containsKey('key1'), isTrue);
        expect(cache['key1'], isNull);
      });

      test('should handle complex value types', () {
        final cache = LRUCache<String, List<int>>(maxCacheSize: 3);

        cache['key1'] = [1, 2, 3];
        cache['key2'] = [4, 5, 6];

        expect(cache['key1'], [1, 2, 3]);
        expect(cache['key2'], [4, 5, 6]);
      });

      test('should handle large number of insertions', () {
        final cache = LRUCache<int, String>(maxCacheSize: 100);

        // Insert 200 entries
        for (var i = 0; i < 200; i++) {
          cache[i] = 'value_$i';
        }

        // First 100 should be evicted
        for (var i = 0; i < 100; i++) {
          expect(cache.containsKey(i), isFalse);
        }

        // Last 100 should remain
        for (var i = 100; i < 200; i++) {
          expect(cache.containsKey(i), isTrue);
          expect(cache[i], 'value_$i');
        }
      });
    });

    group('Default Constructor', () {
      test('should use default cache size of 100', () {
        final cache = LRUCache<String, int>();

        // Fill cache with 100 entries
        for (var i = 0; i < 100; i++) {
          cache['key_$i'] = i;
        }

        // All should be present
        for (var i = 0; i < 100; i++) {
          expect(cache.containsKey('key_$i'), isTrue);
        }

        // Add 101st entry, should evict first
        cache['key_100'] = 100;

        expect(cache.containsKey('key_0'), isFalse);
        expect(cache.containsKey('key_100'), isTrue);
      });
    });
  });
}
