!*********************************************************************
module clocks
!*********************************************************************
!
! This module provides the clock data type (object) and the
! subroutines/functions that act on instances of the clock data type.
!
use types, only : rprec
implicit none

save 
private

public clock_type, &
     clock_time, &
     clock_start, &
     clock_stop

type clock_type
   real(rprec) :: start
   real(rprec) :: stop
end type clock_type

!---------------------------------------------------------------------
contains
!---------------------------------------------------------------------

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
function clock_time( this ) result( time )
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
!
! Returns the time between the latest clock start and stop
!
implicit none

type(clock_type), intent(in) :: this
real(rprec) :: time

time = this % stop - this % start

return
end function clock_time

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine clock_start( this )
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
implicit none

type(clock_type), intent(inout) :: this

call cpu_time( this % start )

return
end subroutine clock_start

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine clock_stop( this )
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
implicit none

type(clock_type), intent(inout) :: this

call cpu_time( this % stop )

return
end subroutine clock_stop

end module clocks
