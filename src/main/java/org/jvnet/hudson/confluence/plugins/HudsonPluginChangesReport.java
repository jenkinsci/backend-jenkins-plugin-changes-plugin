package org.jvnet.hudson.confluence.plugins;

import java.io.File;
import java.io.FileWriter;
import java.io.InputStream;
import java.io.IOException;
import java.util.Date;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.apache.commons.io.IOUtils;

/**
 * Execute a perl script that generates a wiki report of unreleased plugin changes
 * in Hudson's subversion repository.
 * @author Alan Harder (mindless@dev.java.net)
 */
public class HudsonPluginChangesReport {

    public static void main(String[] args) {
        Map params = new HashMap();
        if (args.length > 0) params.put("prefix", args[0]);
        System.out.print(new HudsonPluginChangesReport().execute(params, System.in));
    }

    public String execute(Map parameters, InputStream bodyStream) {
        File tmp = null;
        try {
            String body = IOUtils.toString(bodyStream);

            // Write temp file with map data plus perl code for report
            tmp = File.createTempFile("hudson-plugin-changes", ".pl");
            FileWriter out = new FileWriter(tmp);
            out.write("\nuse strict;\nmy (%knownRevs, %skipTag, %skipEntry, %tagMap);\n"
                      + parseBody(body) + ");\n\n");
            InputStream in = getClass().getResourceAsStream("/report.pl");
            if (in != null) {
                IOUtils.copy(in, out);
                in.close();
            }
            out.close();

            // Run report
            long time = System.currentTimeMillis();
            String startStr = new Date().toString();
            String prefix = (String)parameters.get("prefix");
            if (prefix == null || !prefix.matches("[a-zA-Z\\[\\]*.-]+")) prefix = "";
            final Process p = new ProcessBuilder(
                "perl", tmp.getAbsolutePath(), prefix).redirectErrorStream(true).start();
            p.getOutputStream().close();
            String rpt = IOUtils.toString(p.getInputStream());
            p.getInputStream().close();

            // Group results and wikify
            rpt = wikify(rpt);
            time = System.currentTimeMillis() - time;
            return rpt + "\nGenerated at: " + startStr + " in "
                   + time/60000 + " min " + (time%60000)/1000 + " sec.\n";
        }
        catch (IOException e) {
            return "{warning:title=Report Script Error}\n"
                   + "IOException: " + e.getMessage() + "\n" + "{warning}\n";
        }
        finally {
            if (tmp != null) tmp.delete();
        }
    }

    private static String parseBody(String body) {
        // Parse macro body and convert into perl variable definitions:
        int section = 0, i;
        final String[] mapVars = { "skipTag", "skipEntry", "tagMap" };
        final StringBuilder mapBuf = new StringBuilder("%knownRevs = (\n");
        final String tokenChars = "[a-zA-Z0-9+._-]+";
        final Pattern knownRev = Pattern.compile(
            "\\s*(" + tokenChars + ")\\s*\\|\\s*([ a-zA-Z0-9~!@%*()\\[\\]|;:+=,.<>/?_-]+?)\\s*"),
                tokenPat = Pattern.compile("\\s*(" + tokenChars + ")\\s*"),
                tagMap = Pattern.compile(
            "\\s*(" + tokenChars + ")\\s*\\|\\s*(" + tokenChars + ")\\s*");
        Matcher m;
        for (String line : body.split("[\\n\\r]+")) {
            if ((i = line.indexOf("#")) >= 0) {
                line = line.substring(0, i).trim();  // Remove inline comment
                if (line.length() == 0) continue;
            }
            if (line.startsWith("----")) {
                mapBuf.append(");\n%").append(mapVars[section++]).append(" = (\n");
                continue;
            }
            switch (section) {
              case 0: // %knownRevs
                if ((m = knownRev.matcher(line)).matches())
                    mapBuf.append(" '").append(m.group(1))
                          .append("' => '").append(m.group(2)).append("',\n");
                break;
              case 1: // %skipTag
              case 2: // %skipEntry
                if ((m = tokenPat.matcher(line)).matches())
                    mapBuf.append(" '").append(m.group(1)).append("' => 1,\n");
                break;
              case 3: // %tagMap
                if ((m = tagMap.matcher(line)).matches())
                    mapBuf.append(" '").append(m.group(1))
                          .append("' => '").append(m.group(2)).append("',\n");
                break;
            }
        }
        return mapBuf.toString();
    }

    private static String wikify(String report) {
        final StringBuilder current = new StringBuilder(), unreleased = new StringBuilder(),
                            other = new StringBuilder();
        StringBuilder last = other;
        for (String line : report.split("[\\n\\r]+")) {
            if (line.charAt(0) != '|')                last.append(line).append('\n');
            else if (line.indexOf("CURRENT") > 0)    (last=current).append(line).append('\n');
            else if (line.indexOf("unreleased") > 0) (last=unreleased).append(line).append('\n');
            else                                     (last=other).append(line).append('\n');
        }
        return "h3. Plugin Changes\n" + other
               + "\nh3. Unreleased Plugins\n" + unreleased
               + "\nh3. Current Plugins\n" + current + "\n";
    }
}
