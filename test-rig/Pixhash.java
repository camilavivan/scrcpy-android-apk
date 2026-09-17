// Verify a screencap. The default checks non-uniformity. --pattern also
// requires the four large color fields drawn by the debug Pattern activity,
// so ordinary app chrome cannot make a black video surface pass.
//
//   java test-rig/Pixhash.java <png>            # default min=5%
//   java test-rig/Pixhash.java <png> --pattern
//
// ImageIO/BufferedImage live in java.desktop, which the image's
// openjdk-17-jdk-headless package does ship (headless only disables
// display/input, not imaging) - no extra dependency needed.

import java.io.File;
import java.io.IOException;
import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;

public final class Pixhash {

    public static void main(String[] args) throws IOException {
        if (args.length < 1) usage();
        double minPercent = 5.0;
        boolean pattern = false;
        for (int i = 1; i < args.length; i++) {
            if ("--min".equals(args[i])) {
                if (++i >= args.length) usage();
                try {
                    minPercent = Double.parseDouble(args[i]);
                } catch (NumberFormatException e) {
                    usage();
                }
            } else if ("--pattern".equals(args[i])) {
                pattern = true;
            } else {
                usage();
            }
        }
        if (!Double.isFinite(minPercent) || minPercent < 0.0 || minPercent > 100.0) {
            usage();
        }

        BufferedImage img = ImageIO.read(new File(args[0]));
        if (img == null) {
            System.err.println("pixhash: could not read " + args[0]);
            System.exit(2);
        }

        int w = img.getWidth(), h = img.getHeight();
        int ref = img.getRGB(0, 0);
        long total = (long) w * h;
        long diff = 0;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (img.getRGB(x, y) != ref) diff++;
            }
        }
        double pct = 100.0 * diff / total;
        System.out.printf("pixhash: %d/%d differ from (0,0)=%08x  =>  %.2f%%%n",
                diff, total, ref, pct);
        if (pct < minPercent) {
            System.err.printf("pixhash: only %.2f%% differ, need %.2f%%%n", pct, minPercent);
            System.exit(1);
        }
        if (pattern) checkPattern(img);
    }

    private static void usage() {
        System.err.println("usage: java Pixhash.java <png> [--min N] [--pattern]");
        System.exit(2);
    }

    private static void checkPattern(BufferedImage img) {
        long red = 0, green = 0, blue = 0, yellow = 0, sampled = 0;
        // Sampling every fourth pixel keeps the check cheap on 1080p images.
        for (int y = 0; y < img.getHeight(); y += 4) {
            for (int x = 0; x < img.getWidth(); x += 4) {
                int rgb = img.getRGB(x, y);
                int r = (rgb >>> 16) & 0xff;
                int g = (rgb >>> 8) & 0xff;
                int b = rgb & 0xff;
                sampled++;
                if (r >= 140 && g <= 110 && b <= 110) red++;
                else if (g >= 110 && r <= 120 && b <= 120) green++;
                else if (b >= 140 && r <= 110 && g <= 130) blue++;
                else if (r >= 140 && g >= 120 && b <= 120) yellow++;
            }
        }
        double rp = 100.0 * red / sampled;
        double gp = 100.0 * green / sampled;
        double bp = 100.0 * blue / sampled;
        double yp = 100.0 * yellow / sampled;
        System.out.printf("pixhash: pattern red=%.2f green=%.2f blue=%.2f yellow=%.2f%%%n",
                rp, gp, bp, yp);
        // A rotated 16:9 target fills only about one third of a portrait
        // source after correct letterboxing. Require every field and strong
        // combined coverage rather than assuming the video fills the screen.
        if (rp < 5.0 || gp < 5.0 || bp < 5.0 || yp < 5.0
                || rp + gp + bp + yp < 25.0) {
            System.err.println("pixhash: expected four-color target pattern was not rendered");
            System.exit(1);
        }
    }
}
