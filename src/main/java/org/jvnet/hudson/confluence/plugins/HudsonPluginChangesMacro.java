package org.jvnet.hudson.confluence.plugins;

import java.util.Map;
import com.atlassian.renderer.RenderContext;
import com.atlassian.renderer.v2.RenderMode;
import com.atlassian.renderer.v2.SubRenderer;
import com.atlassian.renderer.v2.macro.BaseMacro;
import com.atlassian.renderer.v2.macro.MacroException;

/**
 * This macro wraps a call to {hudson-plugin-changes-internal} in a {cache} macro.
 * Accepts cacheRefresh=## parameter to override default cache time of seven days.
 * ## is number followed by d or h (for days/hours; min/sec not allowed.. too short!).
 * @author Alan.Harder@sun.com
 */
public class HudsonPluginChangesMacro extends BaseMacro {

    public boolean isInline() {
        return false;
    }
    
    public boolean hasBody() {
        return true;
    }
    
    public RenderMode getBodyRenderMode() {
        return null;  // null means this macro returns wiki text not html
    }
    
    public String execute(Map parameters, String body, RenderContext renderContext)
            throws MacroException {
        // How long to cache results
        String cacheRefresh = (String)parameters.get("cacheRefresh");
        if (cacheRefresh == null || !cacheRefresh.matches("\\d+[hd]"))
            cacheRefresh = "7d";

        // For testing, limit the set of plugins in report
        String param = (String)parameters.get("prefix");
        param = (param == null) ? "}" : ":prefix=" + param + "}";

        // Set a context param so -internal macro knows it is not called directly.
        renderContext.addParam("hudson-plugin-changes-passthru", "ok");

        return "{cache:refresh=" + cacheRefresh + "|checkAttachments=false}{hudson-plugin"
             + "-changes-internal" + param + body + "{hudson-plugin-changes-internal}{cache}\n";
    }
}
