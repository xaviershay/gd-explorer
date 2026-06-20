/* Self-contained LZ4 *block* format decompressor.
 *
 * Grim Dawn's ARZ/ARC files store records as raw LZ4 blocks with the
 * decompressed size known up-front (from the file's own headers). We do not
 * depend on the system liblz4 (no -dev package is required); the block format
 * is small and stable, so we vendor a minimal safe decoder here.
 *
 * Returns the number of bytes written to dst on success, or a negative value
 * on any malformed input or bounds violation.
 */

#include <string.h>

int gd_lz4_decompress_block(const unsigned char *src, int srcSize,
                            unsigned char *dst, int dstCapacity)
{
    const unsigned char *ip = src;
    const unsigned char *const iend = src + srcSize;
    unsigned char *op = dst;
    unsigned char *const oend = dst + dstCapacity;

    if (srcSize < 0 || dstCapacity < 0) return -1;

    while (ip < iend) {
        unsigned token = *ip++;

        /* literal length */
        unsigned length = token >> 4;
        if (length == 15) {
            unsigned s;
            do {
                if (ip >= iend) return -1;
                s = *ip++;
                length += s;
            } while (s == 255);
        }

        /* copy literals */
        if (length > (unsigned)(oend - op)) return -1;
        if (length > (unsigned)(iend - ip)) return -1;
        memcpy(op, ip, length);
        op += length;
        ip += length;

        /* the last sequence of a block is literals only */
        if (ip >= iend) break;

        /* match offset (little-endian u16) */
        if ((iend - ip) < 2) return -1;
        unsigned offset = (unsigned)ip[0] | ((unsigned)ip[1] << 8);
        ip += 2;
        if (offset == 0) return -1;

        unsigned char *match = op - offset;
        if (match < dst) return -1;

        /* match length */
        unsigned mlength = token & 0x0F;
        if (mlength == 15) {
            unsigned s;
            do {
                if (ip >= iend) return -1;
                s = *ip++;
                mlength += s;
            } while (s == 255);
        }
        mlength += 4; /* minmatch */

        if (mlength > (unsigned)(oend - op)) return -1;

        /* overlapping copy must proceed byte-by-byte */
        {
            unsigned i;
            for (i = 0; i < mlength; i++) {
                *op++ = *match++;
            }
        }
    }

    return (int)(op - dst);
}
