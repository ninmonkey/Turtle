describe Turtle {
    it "Draws things with simple commands" {
        $null = $turtle.Clear().Square()
        $turtleSquaredPoints = $turtle.Points       
        $turtleSquaredPoints.Length | Should -Be 8
        $turtleSquaredPoints | 
            Measure-Object -Sum | 
            Select-Object -ExpandProperty Sum | 
            Should -Be 0
    } 

    it 'Can draw an L-system, like a Sierpinski triangle' {
        $turtle.Clear().SierpinskiTriangle(200, 2, 120).points.Count |
            Should -Be 54
    }

    it 'Can rasterize an image, with a little help from chromium' {
        $png = New-Turtle | Move-Turtle SierpinskiTriangle 15 5 | Select-Object -ExpandProperty PNG
        $png[1..3] -as 'char[]' -as 'string[]' -join '' | Should -Be PNG
    }
}
